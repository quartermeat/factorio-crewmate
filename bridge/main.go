package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const version = "0.2.1"

var (
	address    = flag.String("rcon", "127.0.0.1:27015", "address of the game's RCON port")
	password   = flag.String("password", "", "RCON password (default: $CREWMATE_RCON_PASSWORD)")
	save       = flag.String("save", filepath.Join(home(), ".factorio/saves/fast-forward-fleet.zip"), "save to host, for `serve`")
	executable = flag.String("factorio", filepath.Join(home(), ".steam/steam/steamapps/common/Factorio/bin/x64/factorio"), "factorio executable")
	data       = flag.String("data", filepath.Join(home(), ".local/share/factorio-crewmate"), "write-data directory for the hosted server")
	mods       = flag.String("mods", filepath.Join(home(), ".factorio/mods"), "mod directory the server loads")
)

func home() string {
	path, err := os.UserHomeDir()
	if err != nil {
		return "."
	}
	return path
}

// Password order: flag, environment, then the file setup.py writes. The file
// fallback is what lets the MCP registration be a bare command with no secret in
// it -- Claude Code stores that config in the clear.
func secret() string {
	if *password != "" {
		return *password
	}
	if value := os.Getenv("CREWMATE_RCON_PASSWORD"); value != "" {
		return value
	}
	contents, err := os.ReadFile(filepath.Join(home(), ".config/crewmate/env"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(contents), "\n") {
		if value, found := strings.CutPrefix(strings.TrimSpace(line), "CREWMATE_RCON_PASSWORD="); found {
			return value
		}
	}
	return ""
}

func usage() {
	fmt.Fprintf(os.Stderr, `crewmate %s -- a bridge between an agent and a running Factorio game.

  crewmate serve          host the save as a server with RCON open, so a client can join it
  crewmate mcp            run as an MCP server on stdio, for Claude Code to drive
  crewmate call <fn> [json]   one remote call against the running game, for poking at it by hand
  crewmate exec <command>     one raw console command, for the same reason

Flags:
`, version)
	flag.PrintDefaults()
}

// Flags are accepted on either side of the subcommand. The flag package stops at
// the first non-flag argument, so `serve -save x.zip` would otherwise parse as a
// bare subcommand and silently host whatever the default is.
func parseCommand(arguments []string) (string, []string, error) {
	if err := flag.CommandLine.Parse(arguments); err != nil {
		return "", nil, err
	}
	rest := flag.Args()
	if len(rest) == 0 {
		return "", nil, nil
	}
	command := rest[0]
	if err := flag.CommandLine.Parse(rest[1:]); err != nil {
		return "", nil, err
	}
	return command, flag.Args(), nil
}

func main() {
	flag.Usage = usage
	command, arguments, err := parseCommand(os.Args[1:])
	if err != nil {
		os.Exit(2)
	}
	if command == "" {
		usage()
		os.Exit(2)
	}

	argument := func(index int) string {
		if index < len(arguments) {
			return arguments[index]
		}
		return ""
	}

	switch command {
	case "serve":
		err = serve()
	case "mcp":
		err = withGame(ServeMCP)
	case "call":
		err = call(argument(0), argument(1))
	case "exec":
		err = execute(strings.Join(arguments, " "))
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "crewmate:", err)
		os.Exit(1)
	}
}

func withGame(run func(*Game) error) error {
	if secret() == "" {
		return fmt.Errorf("no RCON password; set CREWMATE_RCON_PASSWORD or pass -password")
	}
	client, err := Dial(*address, secret(), 5*time.Second)
	if err != nil {
		return err
	}
	defer client.Close()
	return run(&Game{client: client})
}

func call(function, argument string) error {
	if function == "" {
		return fmt.Errorf("which function? e.g. crewmate call status")
	}
	var parsed any = map[string]any{}
	if argument != "" {
		if err := json.Unmarshal([]byte(argument), &parsed); err != nil {
			return fmt.Errorf("argument is not JSON: %w", err)
		}
	}
	return withGame(func(game *Game) error {
		result, err := game.Call(function, parsed)
		if err != nil {
			return err
		}
		var pretty any
		json.Unmarshal(result, &pretty)
		encoder := json.NewEncoder(os.Stdout)
		encoder.SetIndent("", "  ")
		return encoder.Encode(pretty)
	})
}

func execute(command string) error {
	if command == "" {
		return fmt.Errorf("which command?")
	}
	return withGame(func(game *Game) error {
		// Plain chat and many commands answer with nothing at all, which the
		// socket reports as a read timeout. That is not a failure.
		reply, err := game.client.Exec(command)
		if err != nil && !errors.Is(err, os.ErrDeadlineExceeded) {
			return err
		}
		if trimmed := strings.TrimSpace(reply); trimmed != "" {
			fmt.Println(trimmed)
		}
		return nil
	})
}

// Hosting writes its own settings and write-data directory: the graphical game
// holds a lock on ~/.factorio, so the server cannot share it while you play.
func serve() error {
	if secret() == "" {
		return fmt.Errorf("no RCON password; set CREWMATE_RCON_PASSWORD or pass -password")
	}
	if _, err := os.Stat(*save); err != nil {
		return fmt.Errorf("save not found: %s", *save)
	}
	if err := os.MkdirAll(*data, 0o755); err != nil {
		return err
	}

	config := filepath.Join(*data, "config.ini")
	contents := fmt.Sprintf("[path]\nread-data=__PATH__executable__/../../data\nwrite-data=%s\n", *data)
	if err := os.WriteFile(config, []byte(contents), 0o644); err != nil {
		return err
	}

	settings := filepath.Join(*data, "server-settings.json")
	if err := os.WriteFile(settings, serverSettings(), 0o644); err != nil {
		return err
	}

	port := strings.TrimPrefix(*address, "127.0.0.1:")
	// Factorio logs that it started the RCON interface whether or not the bind
	// succeeded, so a second server on the same port looks healthy while every
	// command quietly goes to the first one. Refuse to start instead.
	listener, err := net.Listen("tcp", *address)
	if err != nil {
		return fmt.Errorf("%s is already in use -- another server is probably still running: %w", *address, err)
	}
	listener.Close()
	arguments := []string{
		"--start-server", *save,
		"--config", config,
		"--mod-directory", *mods,
		"--server-settings", settings,
		"--rcon-port", port,
		"--rcon-password", secret(),
	}
	game := exec.Command(*executable, arguments...)
	game.Stdout = os.Stdout
	game.Stderr = os.Stderr
	if err := game.Start(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "crewmate: hosting %s, rcon on %s; join at 127.0.0.1\n", filepath.Base(*save), *address)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- game.Wait() }()
	select {
	case <-stop:
		game.Process.Signal(syscall.SIGINT)
		return <-done
	case err := <-done:
		return err
	}
}

func serverSettings() []byte {
	settings := map[string]any{
		"name":                      "Crewmate",
		"description":               "Local game with an agent aboard.",
		"visibility":                map[string]any{"public": false, "lan": true},
		"require_user_verification": false,
		"auto_pause":                false,
		"allow_commands":            "admins-only",
		"autosave_interval":         10,
		"autosave_slots":            5,
		"maximum_segment_size":      100,
	}
	encoded, _ := json.MarshalIndent(settings, "", "  ")
	return encoded
}
