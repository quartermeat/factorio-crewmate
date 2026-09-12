package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

// Calls into the mod's remote interface. Arguments travel as a JSON string that
// the mod parses, which keeps Lua quoting to a single escaped literal instead of
// a different hand-built expression per call.
type Game struct {
	client *RCON
}

type Reply struct {
	OK     bool            `json:"ok"`
	Error  string          `json:"error"`
	Result json.RawMessage `json:"result"`
}

func luaString(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `'`, `\'`, "\n", `\n`, "\r", `\r`)
	return "'" + replacer.Replace(value) + "'"
}

// The first console command on a save answers the "this disables achievements"
// prompt instead of running, and says so only in the server log. Repeating it is
// what the prompt asks for, so a silent reply is retried once rather than
// surfaced as a mystery timeout.
func (g *Game) exec(command string) (string, error) {
	for attempt := 0; attempt < 2; attempt++ {
		raw, err := g.client.Exec(command)
		if err != nil && !errors.Is(err, os.ErrDeadlineExceeded) {
			return "", err
		}
		if trimmed := strings.TrimSpace(raw); trimmed != "" {
			return trimmed, nil
		}
	}
	return "", nil
}

func (g *Game) Call(function string, argument any) (json.RawMessage, error) {
	encoded, err := json.Marshal(argument)
	if err != nil {
		return nil, err
	}
	command := fmt.Sprintf(`/sc rcon.print(remote.call("crewmate", %s, helpers.json_to_table(%s)))`,
		luaString(function), luaString(string(encoded)))

	raw, err := g.exec(command)
	if err != nil {
		return nil, err
	}
	if raw == "" {
		return nil, fmt.Errorf("no reply from the game; is the crewmate mod enabled on the server?")
	}

	var reply Reply
	if err := json.Unmarshal([]byte(raw), &reply); err != nil {
		return nil, fmt.Errorf("unexpected reply from the game: %s", raw)
	}
	if !reply.OK {
		return nil, fmt.Errorf("%s", reply.Error)
	}
	return reply.Result, nil
}
