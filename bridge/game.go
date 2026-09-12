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
	client console
}

// Narrow enough that tests can stand in for a whole game.
type console interface {
	Exec(command string) (string, error)
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
	return normalize(reply.Result), nil
}

// Lua has one table type, so an empty list and an empty map both leave the game
// as `{}`: a field that is an array when the factory is busy becomes an object
// when it is idle. Rewriting every empty object to `[]` costs nothing -- empty is
// empty either way -- and spares whatever reads this from having to handle a
// field whose type depends on the weather.
func normalize(raw json.RawMessage) json.RawMessage {
	var decoded any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return raw
	}
	encoded, err := json.Marshal(emptyToArray(decoded))
	if err != nil {
		return raw
	}
	return encoded
}

func emptyToArray(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		if len(typed) == 0 {
			return []any{}
		}
		for key, nested := range typed {
			typed[key] = emptyToArray(nested)
		}
		return typed
	case []any:
		for index, nested := range typed {
			typed[index] = emptyToArray(nested)
		}
		return typed
	default:
		return value
	}
}
