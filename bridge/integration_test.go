package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// The real thing: generate a map, host it, and drive a body around in it. Needs
// a Factorio install, so it is opt-in.
//
//	CREWMATE_INTEGRATION=1 go test -run Integration -v
func TestIntegrationBodyLivesInTheGame(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	factorio := *executable
	if _, err := os.Stat(factorio); err != nil {
		t.Skipf("no Factorio at %s", factorio)
	}

	work := t.TempDir()
	mods := filepath.Join(work, "mods")
	if err := os.MkdirAll(mods, 0o755); err != nil {
		t.Fatal(err)
	}
	source, err := filepath.Abs("../mod")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(source, filepath.Join(mods, "crewmate")); err != nil {
		t.Fatal(err)
	}

	config := filepath.Join(work, "config.ini")
	contents := fmt.Sprintf("[path]\nread-data=__PATH__executable__/../../data\nwrite-data=%s\n", work)
	if err := os.WriteFile(config, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}

	save := filepath.Join(work, "test.zip")
	create := exec.Command(factorio, "--create", save, "--config", config, "--mod-directory", mods)
	if output, err := create.CombinedOutput(); err != nil {
		t.Fatalf("map creation failed: %v\n%s", err, output)
	}

	port := freePort(t)
	settings := filepath.Join(work, "server-settings.json")
	if err := os.WriteFile(settings, serverSettings(), 0o644); err != nil {
		t.Fatal(err)
	}
	server := exec.Command(factorio,
		"--start-server", save,
		"--config", config,
		"--mod-directory", mods,
		"--server-settings", settings,
		"--rcon-port", port,
		"--rcon-password", "integration",
	)
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		server.Process.Kill()
		server.Wait()
	})

	address := "127.0.0.1:" + port
	client := waitForRCON(t, address, "integration")
	defer client.Close()
	game := &Game{client: client}

	if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": map[string]int{"x": 0, "y": 0}}); err != nil {
		t.Fatalf("spawn: %v", err)
	}

	target := map[string]int{"x": 20, "y": 0}
	if _, err := game.Call("walk_to", target); err != nil {
		t.Fatalf("walk_to: %v", err)
	}

	deadline := time.Now().Add(30 * time.Second)
	var arrived bool
	for time.Now().Before(deadline) && !arrived {
		time.Sleep(time.Second)
		raw, err := game.Call("status", nil)
		if err != nil {
			t.Fatalf("status: %v", err)
		}
		var status struct {
			Body struct {
				Position struct{ X, Y float64 }
				Doing    string
				Health   float64
			}
		}
		if err := json.Unmarshal(raw, &status); err != nil {
			t.Fatalf("status is not the shape the bridge expects: %s", raw)
		}
		if status.Body.Health <= 0 {
			t.Fatal("body reported no health")
		}
		arrived = math.Abs(status.Body.Position.X-20) < 2 && status.Body.Doing == "idle"
	}
	if !arrived {
		t.Fatal("body never reached its destination")
	}

	raw, err := game.Call("look", map[string]any{"radius": 32})
	if err != nil {
		t.Fatalf("look: %v", err)
	}
	var seen struct {
		Counts []struct {
			Name  string
			Count int
		}
	}
	if err := json.Unmarshal(raw, &seen); err != nil {
		t.Fatalf("look is not the shape the bridge expects: %s", raw)
	}

	if _, err := game.Call("say", map[string]any{"message": "integration test says hello"}); err != nil {
		t.Fatalf("say: %v", err)
	}
	heard, err := game.Call("hear", nil)
	if err != nil {
		t.Fatalf("hear: %v", err)
	}
	t.Logf("walked to x=20, saw %d kinds of thing nearby, chat buffer %s", len(seen.Counts), heard)
}

func freePort(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	return port
}

func waitForRCON(t *testing.T, address, password string) *RCON {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		client, err := Dial(address, password, 2*time.Second)
		if err == nil {
			return client
		}
		time.Sleep(time.Second)
	}
	t.Fatal("server never opened its RCON port")
	return nil
}
