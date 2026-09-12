package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// A minimal MCP server over stdio: initialize, tools/list, tools/call. Nothing
// here needs a framework, and a dependency-free binary is easier to trust with a
// socket into a live game.
const protocolVersion = "2024-11-05"

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type Tool struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Call        string         `json:"-"`
}

func object(properties map[string]any, required ...string) map[string]any {
	if required == nil {
		required = []string{}
	}
	return map[string]any{"type": "object", "properties": properties, "required": required}
}

func number(description string) map[string]any {
	return map[string]any{"type": "number", "description": description}
}

func text(description string) map[string]any {
	return map[string]any{"type": "string", "description": description}
}

func tools() []Tool {
	return []Tool{
		{
			Name:        "factory_status",
			Description: "Overall state of the game: where the crewmate's body is and what it is doing, connected players, current research, pollution, what the factory produced and consumed in the last minute, machines currently stalled, and any space platforms.",
			InputSchema: object(map[string]any{}),
			Call:        "status",
		},
		{
			Name:        "crew_look",
			Description: "What is around the crewmate right now: entity counts, the nearest notable entities with their status, and ore patches within the radius.",
			InputSchema: object(map[string]any{"radius": number("tiles to look out to, default 32, max 128")}),
			Call:        "look",
		},
		{
			Name:        "crew_hear",
			Description: "Chat said in game since the last call. Drains what it returns.",
			InputSchema: object(map[string]any{}),
			Call:        "hear",
		},
		{
			Name:        "crew_say",
			Description: "Say something in the game's chat, tagged as the crewmate.",
			InputSchema: object(map[string]any{"message": text("what to say")}, "message"),
			Call:        "say",
		},
		{
			Name:        "crew_spawn",
			Description: "Put a body in the world, next to a connected player by default. Replaces any existing body.",
			InputSchema: object(map[string]any{
				"player":  text("player name to spawn beside"),
				"surface": text("surface name, default nauvis"),
			}),
			Call: "spawn",
		},
		{
			Name:        "crew_walk_to",
			Description: "Walk the body to a map position. It steers in a straight line and sidesteps obstacles; it is not a path finder.",
			InputSchema: object(map[string]any{"x": number("map x"), "y": number("map y")}, "x", "y"),
			Call:        "walk_to",
		},
		{
			Name:        "crew_follow",
			Description: "Follow a player around until told otherwise.",
			InputSchema: object(map[string]any{"player": text("player name, default the first player")}),
			Call:        "follow",
		},
		{
			Name:        "crew_halt",
			Description: "Stop walking and stand still.",
			InputSchema: object(map[string]any{}),
			Call:        "halt",
		},
		{
			Name:        "crew_screenshot",
			Description: "Render a screenshot from the body's position and return its file path. Requires a graphical client to be joined: a headless server cannot draw.",
			InputSchema: object(map[string]any{
				"zoom":   number("zoom, default 0.6; lower sees more"),
				"width":  number("pixels, default 1280"),
				"height": number("pixels, default 720"),
			}),
			Call: "screenshot",
		},
	}
}

type MCP struct {
	game *Game
	out  *json.Encoder
}

func ServeMCP(game *Game) error {
	server := &MCP{game: game, out: json.NewEncoder(os.Stdout)}
	reader := bufio.NewReaderSize(os.Stdin, 1<<20)
	decoder := json.NewDecoder(reader)
	for {
		var message request
		if err := decoder.Decode(&message); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		server.handle(message)
	}
}

func (m *MCP) reply(id json.RawMessage, result any) {
	m.out.Encode(response{JSONRPC: "2.0", ID: id, Result: result})
}

func (m *MCP) fail(id json.RawMessage, code int, message string) {
	m.out.Encode(response{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: message}})
}

func (m *MCP) handle(message request) {
	switch message.Method {
	case "initialize":
		m.reply(message.ID, map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "crewmate", "version": version},
		})
	case "ping":
		m.reply(message.ID, map[string]any{})
	case "tools/list":
		list := []Tool{}
		list = append(list, tools()...)
		m.reply(message.ID, map[string]any{"tools": list})
	case "tools/call":
		m.callTool(message)
	default:
		if len(message.ID) > 0 {
			m.fail(message.ID, -32601, "unknown method: "+message.Method)
		}
	}
}

func (m *MCP) callTool(message request) {
	var params struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(message.Params, &params); err != nil {
		m.fail(message.ID, -32602, err.Error())
		return
	}
	for _, tool := range tools() {
		if tool.Name != params.Name {
			continue
		}
		result, err := m.game.Call(tool.Call, params.Arguments)
		if err != nil {
			m.reply(message.ID, map[string]any{
				"content": []any{map[string]any{"type": "text", "text": err.Error()}},
				"isError": true,
			})
			return
		}
		m.reply(message.ID, map[string]any{
			"content": []any{map[string]any{"type": "text", "text": string(result)}},
		})
		return
	}
	m.fail(message.ID, -32602, fmt.Sprintf("unknown tool: %s", params.Name))
}
