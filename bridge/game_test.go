package main

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

type scriptedConsole struct {
	commands []string
	replies  []string
	err      error
}

func (c *scriptedConsole) Exec(command string) (string, error) {
	c.commands = append(c.commands, command)
	if c.err != nil {
		return "", c.err
	}
	if len(c.replies) == 0 {
		return "", nil
	}
	reply := c.replies[0]
	c.replies = c.replies[1:]
	return reply, nil
}

func TestCallSendsJSONArgument(t *testing.T) {
	console := &scriptedConsole{replies: []string{`{"ok":true,"result":{"walking_to":{"x":5,"y":-3}}}`}}
	game := &Game{client: console}

	result, err := game.Call("walk_to", map[string]any{"x": 5, "y": -3})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(result), `"walking_to"`) {
		t.Fatalf("result not unwrapped: %s", result)
	}
	sent := console.commands[0]
	if !strings.HasPrefix(sent, "/sc rcon.print(remote.call(") {
		t.Fatalf("not a remote call: %s", sent)
	}
	if !strings.Contains(sent, `helpers.json_to_table('{"x":5,"y":-3}')`) {
		t.Fatalf("argument not passed as JSON: %s", sent)
	}
}

func TestCallSurfacesModError(t *testing.T) {
	game := &Game{client: &scriptedConsole{replies: []string{`{"ok":false,"error":"no body in the world"}`}}}
	if _, err := game.Call("walk_to", nil); err == nil || err.Error() != "no body in the world" {
		t.Fatalf("mod error not surfaced: %v", err)
	}
}

// The console swallows the first command on a save to ask about achievements.
func TestCallRetriesSilentFirstCommand(t *testing.T) {
	console := &scriptedConsole{replies: []string{"", `{"ok":true,"result":{}}`}}
	game := &Game{client: console}
	if _, err := game.Call("status", nil); err != nil {
		t.Fatal(err)
	}
	if len(console.commands) != 2 {
		t.Fatalf("expected the command to be repeated, sent %d", len(console.commands))
	}
}

func TestCallExplainsPersistentSilence(t *testing.T) {
	game := &Game{client: &scriptedConsole{}}
	_, err := game.Call("status", nil)
	if err == nil || !strings.Contains(err.Error(), "crewmate mod") {
		t.Fatalf("silence should point at the mod: %v", err)
	}
}

func TestLuaStringEscapes(t *testing.T) {
	for input, want := range map[string]string{
		`plain`:      `'plain'`,
		`it's`:       `'it\'s'`,
		`back\slash`: `'back\\slash'`,
		"two\nlines": `'two\nlines'`,
	} {
		if got := luaString(input); got != want {
			t.Errorf("luaString(%q) = %s, want %s", input, got, want)
		}
	}
}

// Arguments reach Lua as a JSON literal, so quoting has to survive a message the
// player could plausibly type.
func TestSayWithAwkwardQuotingRoundTrips(t *testing.T) {
	console := &scriptedConsole{replies: []string{`{"ok":true,"result":{}}`}}
	game := &Game{client: console}
	message := `it's "fine", \ really`
	if _, err := game.Call("say", map[string]any{"message": message}); err != nil {
		t.Fatal(err)
	}
	sent := console.commands[0]
	start := strings.Index(sent, "helpers.json_to_table('") + len("helpers.json_to_table('")
	end := strings.LastIndex(sent, "')")
	literal := sent[start:end]
	unescaped := strings.NewReplacer(`\'`, `'`, `\\`, `\`).Replace(literal)

	var decoded map[string]string
	if err := json.Unmarshal([]byte(unescaped), &decoded); err != nil {
		t.Fatalf("Lua literal is not recoverable JSON: %s", literal)
	}
	if decoded["message"] != message {
		t.Fatalf("message mangled: %q", decoded["message"])
	}
}

func TestSecretPrefersFlagThenEnvironment(t *testing.T) {
	defer func(previous string) { *password = previous }(*password)
	*password = "from-flag"
	if secret() != "from-flag" {
		t.Fatal("flag should win")
	}
	*password = ""
	os.Setenv("CREWMATE_RCON_PASSWORD", "from-env")
	defer os.Unsetenv("CREWMATE_RCON_PASSWORD")
	if secret() != "from-env" {
		t.Fatal("environment should be used when no flag is given")
	}
}

func TestEmptyTablesBecomeArrays(t *testing.T) {
	console := &scriptedConsole{replies: []string{
		`{"ok":true,"result":{"counts":{},"body":{"inventory":{},"health":300},"platforms":[{"cargo":{}}]}}`,
	}}
	game := &Game{client: console}
	result, err := game.Call("status", nil)
	if err != nil {
		t.Fatal(err)
	}
	var decoded struct {
		Counts []any `json:"counts"`
		Body   struct {
			Inventory []any   `json:"inventory"`
			Health    float64 `json:"health"`
		} `json:"body"`
		Platforms []struct {
			Cargo []any `json:"cargo"`
		} `json:"platforms"`
	}
	if err := json.Unmarshal(result, &decoded); err != nil {
		t.Fatalf("empty tables still break list fields: %s (%v)", result, err)
	}
	if decoded.Body.Health != 300 {
		t.Fatalf("normalising lost data: %s", result)
	}
}

// `crewmate serve -save x.zip` must honour the flag: Go's flag package stops at
// the subcommand, and a silently ignored -save hosts the wrong world.
func TestFlagsAfterSubcommandAreParsed(t *testing.T) {
	defer func(previous string) { *save = previous }(*save)
	command, rest, err := parseCommand([]string{"serve", "-save", "/tmp/elsewhere.zip"})
	if err != nil {
		t.Fatal(err)
	}
	if command != "serve" {
		t.Fatalf("subcommand lost: %q", command)
	}
	if *save != "/tmp/elsewhere.zip" {
		t.Fatalf("-save after the subcommand was ignored: %q", *save)
	}
	if len(rest) != 0 {
		t.Fatalf("unexpected leftovers: %v", rest)
	}
}

func TestSubcommandArgumentsSurvive(t *testing.T) {
	command, rest, err := parseCommand([]string{"call", "walk_to", `{"x":1}`})
	if err != nil {
		t.Fatal(err)
	}
	if command != "call" || len(rest) != 2 || rest[0] != "walk_to" || rest[1] != `{"x":1}` {
		t.Fatalf("arguments mangled: %q %v", command, rest)
	}
}
