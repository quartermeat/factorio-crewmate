package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const version = "0.10.0"

var (
	address    = flag.String("rcon", "127.0.0.1:27015", "address of the game's RCON port")
	password   = flag.String("password", "", "RCON password (default: $CREWMATE_RCON_PASSWORD)")
	save       = flag.String("save", filepath.Join(home(), ".factorio/saves/fast-forward-fleet.zip"), "save to host, for `serve`")
	executable = flag.String("factorio", filepath.Join(home(), ".steam/steam/steamapps/common/Factorio/bin/x64/factorio"), "factorio executable")
	data       = flag.String("data", filepath.Join(home(), ".local/share/factorio-crewmate"), "write-data directory for the hosted server")
	mods       = flag.String("mods", filepath.Join(home(), ".factorio/mods"), "mod directory the server loads")
	watch      = flag.String("watch", "", "directory to watch; when a file changes, save and restart the server so mod edits take effect")
	gamePort   = flag.Int("port", 34197, "UDP port the game itself listens on; change it to host a second world")
	directives = flag.String("directives", defaultDirectives(), "directory of directive files")
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
// Directives ship with the repo; the binary sits in bridge/ inside it.
func defaultDirectives() string {
	executable, err := os.Executable()
	if err != nil {
		return "directives"
	}
	return filepath.Join(filepath.Dir(executable), "..", "directives")
}

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
  crewmate stop           stop the server this bridge started, and nothing else
  crewmate serve -watch mod   the same, restarting on every mod edit
  crewmate mcp            run as an MCP server on stdio, for Claude Code to drive
  crewmate directive list     what the companion knows how to build
  crewmate directive show <name>   its steps and what it would cost
  crewmate directive run <name> [json]   carry it out; json overrides parameters
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
	case "stop":
		err = stopServer()
	case "mcp":
		err = withGame(ServeMCP)
	case "directive":
		err = directive(argument(0), argument(1), argument(2))
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

func directive(action, name, overrides string) error {
	known, err := LoadDirectives(*directives)
	if err != nil {
		return err
	}

	switch action {
	case "", "list":
		names := make([]string, 0, len(known))
		for name := range known {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			fmt.Println(known[name].Summary())
		}
		return nil
	case "show", "run":
	default:
		return fmt.Errorf("directive list, show <name>, or run <name>")
	}

	chosen, found := known[name]
	if !found {
		return fmt.Errorf("no directive called %q", name)
	}
	parameters := map[string]any{}
	if overrides != "" {
		if err := json.Unmarshal([]byte(overrides), &parameters); err != nil {
			return fmt.Errorf("parameters are not JSON numbers: %w", err)
		}
	}

	if action == "show" {
		fmt.Printf("%s\n%s\n\n", chosen.Title, chosen.Description)
		for index, step := range chosen.Steps {
			verb, _ := step["do"].(string)
			fmt.Printf("  %d. %s\n", index+1, verb)
		}
		return nil
	}

	return withGame(func(game *Game) error {
		spot, err := chosen.FindAnchor(game, nil)
		if err != nil {
			return err
		}
		payload, err := chosen.Compile(spot, parameters)
		if err != nil {
			return err
		}
		if chosen.Blueprint != "" {
			raw, err := game.Call("blueprint_needs", map[string]any{
				"blueprint": chosen.Blueprint,
				"supplies":  payload["requires"],
			})
			if err != nil {
				return err
			}
			fmt.Printf("cost: %s\n", raw)
		}
		result, err := game.Call("run_plan", payload)
		if err != nil {
			return err
		}
		fmt.Printf("started: %s\n", result)
		return nil
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
		"--port", strconv.Itoa(*gamePort),
		"--rcon-password", secret(),
	}
	start := func() (*exec.Cmd, error) {
		game := exec.Command(*executable, arguments...)
		game.Stdout = os.Stdout
		game.Stderr = os.Stderr
		return game, game.Start()
	}

	game, err := start()
	if err != nil {
		return err
	}
	rememberPid(game.Process.Pid)
	defer os.Remove(pidFile())
	fmt.Fprintf(os.Stderr, "crewmate: hosting %s (pid %d), rcon on %s; join at 127.0.0.1\n",
		filepath.Base(*save), game.Process.Pid, *address)

	// Watch for directives asked for from inside the game, for as long as the
	// server is up.
	stopDaemon := make(chan struct{})
	defer close(stopDaemon)
	daemon := &Daemon{Address: *address, Password: secret(), Directives: *directives}
	go daemon.Run(stopDaemon)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	done := make(chan error, 1)
	watching := watchDirectory(*watch)
	go func() { done <- game.Wait() }()

	for {
		select {
		case <-stop:
			return shutdown(game, done)
		case err := <-done:
			return err
		case changed := <-watching:
			// Mods cannot be reloaded live in multiplayer -- reload_mods is
			// documented as doing nothing there, and it does -- so picking up an
			// edit means saving and bouncing the server. Clients reconnect.
			fmt.Fprintf(os.Stderr, "crewmate: %s changed; saving and restarting\n", changed)
			if client, err := Dial(*address, secret(), 2*time.Second); err == nil {
				client.Exec("/server-save")
				client.Close()
			}
			shutdown(game, done)
			waitForPort(*address)
			game, err = start()
			if err != nil {
				return err
			}
			rememberPid(game.Process.Pid)
			go func() { done <- game.Wait() }()
			fmt.Fprintln(os.Stderr, "crewmate: back up")
		}
	}
}

// A detached headless server ignores SIGINT -- its stdin is already at EOF, and
// it sits in a half-quit state accepting RCON connections it never answers --
// so shutdown asks politely with SIGTERM and stops asking after fifteen seconds.
func shutdown(game *exec.Cmd, done <-chan error) error {
	game.Process.Signal(syscall.SIGTERM)
	select {
	case err := <-done:
		return err
	case <-time.After(15 * time.Second):
		fmt.Fprintln(os.Stderr, "crewmate: server did not stop; killing it")
		game.Process.Kill()
		return <-done
	}
}

// The replacement cannot bind while the old socket is still held.
func waitForPort(address string) {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		listener, err := net.Listen("tcp", address)
		if err == nil {
			listener.Close()
			return
		}
		time.Sleep(250 * time.Millisecond)
	}
}

// Polled rather than inotify-driven: one dependency-free goroutine, and a second
// of latency is nothing next to the restart it triggers.
func watchDirectory(directory string) <-chan string {
	changes := make(chan string)
	if directory == "" {
		return changes
	}
	go func() {
		previous := snapshot(directory)
		for range time.Tick(time.Second) {
			current := snapshot(directory)
			for path, modified := range current {
				if was, seen := previous[path]; !seen || !was.Equal(modified) {
					previous = current
					changes <- filepath.Base(path)
					break
				}
			}
			previous = current
		}
	}()
	return changes
}

func snapshot(directory string) map[string]time.Time {
	files := map[string]time.Time{}
	filepath.WalkDir(directory, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		if info, err := entry.Info(); err == nil {
			files[path] = info.ModTime()
		}
		return nil
	})
	return files
}

// A pid file, so stopping this server does not mean hunting for factorio
// processes and killing whatever matches -- which will happily take out a test
// run, or somebody else's game, along with it.
func pidFile() string {
	return filepath.Join(*data, "server.pid")
}

func rememberPid(pid int) {
	os.WriteFile(pidFile(), []byte(strconv.Itoa(pid)), 0o644)
}

func stopServer() error {
	contents, err := os.ReadFile(pidFile())
	if err != nil {
		return fmt.Errorf("no server started from here is running (%s)", pidFile())
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(contents)))
	if err != nil {
		return fmt.Errorf("%s does not hold a process id", pidFile())
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	if err := process.Signal(syscall.SIGTERM); err != nil {
		os.Remove(pidFile())
		return fmt.Errorf("server %d is already gone", pid)
	}
	fmt.Fprintf(os.Stderr, "crewmate: asked server %d to stop\n", pid)
	for attempt := 0; attempt < 60; attempt++ {
		time.Sleep(250 * time.Millisecond)
		if err := process.Signal(syscall.Signal(0)); err != nil {
			os.Remove(pidFile())
			return nil
		}
	}
	return fmt.Errorf("server %d did not stop", pid)
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
