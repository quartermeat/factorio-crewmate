package main

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// ServeMCP reads stdin and writes stdout, so the test swaps both for pipes and
// speaks the protocol at it the way a client would.
func speak(t *testing.T, game *Game, requests ...string) []map[string]any {
	t.Helper()
	inRead, inWrite, _ := os.Pipe()
	outRead, outWrite, _ := os.Pipe()
	stdin, stdout := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = inRead, outWrite
	defer func() { os.Stdin, os.Stdout = stdin, stdout }()

	go func() {
		for _, request := range requests {
			inWrite.WriteString(request + "\n")
		}
		inWrite.Close()
	}()

	done := make(chan error, 1)
	go func() { done <- ServeMCP(game) }()
	if err := <-done; err != nil {
		t.Fatalf("serve: %v", err)
	}
	outWrite.Close()

	var replies []map[string]any
	scanner := bufio.NewScanner(outRead)
	for scanner.Scan() {
		var reply map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &reply); err != nil {
			t.Fatalf("bad JSON on stdout: %s", scanner.Text())
		}
		replies = append(replies, reply)
	}
	return replies
}

func TestInitializeAndListTools(t *testing.T) {
	game := &Game{client: &scriptedConsole{}}
	replies := speak(t, game,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`,
	)
	if len(replies) != 2 {
		t.Fatalf("notifications must not be answered; got %d replies", len(replies))
	}

	result := replies[0]["result"].(map[string]any)
	if result["protocolVersion"] != protocolVersion {
		t.Fatalf("wrong protocol version: %v", result["protocolVersion"])
	}

	listed := replies[1]["result"].(map[string]any)["tools"].([]any)
	if len(listed) != len(tools()) {
		t.Fatalf("listed %d tools, have %d", len(listed), len(tools()))
	}
	for _, entry := range listed {
		tool := entry.(map[string]any)
		if tool["description"] == "" || tool["inputSchema"] == nil {
			t.Fatalf("tool %v is missing its schema or description", tool["name"])
		}
	}
}

func TestToolCallReturnsGameResult(t *testing.T) {
	console := &scriptedConsole{replies: []string{`{"ok":true,"result":{"said":"hello"}}`}}
	replies := speak(t, &Game{client: console},
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"crew_say","arguments":{"message":"hello"}}}`,
	)
	content := replies[0]["result"].(map[string]any)["content"].([]any)[0].(map[string]any)
	if !strings.Contains(content["text"].(string), `"said":"hello"`) {
		t.Fatalf("game result not returned: %v", content)
	}
	if !strings.Contains(console.commands[0], `"crew"`) && !strings.Contains(console.commands[0], "crewmate") {
		t.Fatalf("tool did not reach the mod: %s", console.commands[0])
	}
}

// A game-side failure is a tool result flagged as an error, not a protocol
// error: the model should see the message and be able to act on it.
func TestToolCallReportsGameErrorAsContent(t *testing.T) {
	console := &scriptedConsole{replies: []string{`{"ok":false,"error":"no body in the world"}`}}
	replies := speak(t, &Game{client: console},
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"crew_walk_to","arguments":{"x":1,"y":2}}}`,
	)
	result := replies[0]["result"].(map[string]any)
	if result["isError"] != true {
		t.Fatalf("game failure should be flagged: %v", result)
	}
	if replies[0]["error"] != nil {
		t.Fatal("a game failure is not a protocol error")
	}
}

func TestUnknownToolIsRejected(t *testing.T) {
	replies := speak(t, &Game{client: &scriptedConsole{}},
		`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"crew_launch_nukes","arguments":{}}}`,
	)
	if replies[0]["error"] == nil {
		t.Fatal("unknown tools must be rejected")
	}
}
