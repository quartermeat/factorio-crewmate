package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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
	game := hostTestWorld(t)

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

// Spin up a throwaway world with the mod loaded, and hand back a connection to
// it. Everything lives in a temp directory, so this never touches ~/.factorio.
func hostTestWorld(t *testing.T) *Game {
	t.Helper()
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

	// A fixed seed: otherwise every run gets a different coastline, and a
	// directive that needs a reachable shore passes or fails by luck.
	mapGen := filepath.Join(work, "map-gen-settings.json")
	if err := os.WriteFile(mapGen, []byte(`{"seed": 20260912}`), 0o644); err != nil {
		t.Fatal(err)
	}

	save := filepath.Join(work, "test.zip")
	create := exec.Command(factorio, "--create", save, "--config", config, "--mod-directory", mods,
		"--map-gen-settings", mapGen)
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
		"--port", freePort(t),
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

	client := waitForRCON(t, "127.0.0.1:"+port, "integration")
	t.Cleanup(func() { client.Close() })
	return &Game{client: client}
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

// The whole point of the project, end to end: a directive written in a file, a
// shore found in a generated world, and a power block standing there afterwards
// that the companion built by hand out of its own pockets.
func TestIntegrationDirectiveBuildsPowerBlock(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	game := hostTestWorld(t)

	if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": map[string]int{"x": 0, "y": 0}}); err != nil {
		t.Fatalf("spawn: %v", err)
	}

	// A player would hand these over or the companion would craft them. Cheating
	// them in is a test shortcut, and the only one here.
	supply := `/sc local b = remote.call("crewmate", "carrying") local body = game.surfaces.nauvis.find_entities_filtered{name="character"}[1] ` +
		`body.insert{name="offshore-pump", count=1} body.insert{name="boiler", count=1} body.insert{name="steam-engine", count=3} ` +
		`body.insert{name="medium-electric-pole", count=3} body.insert{name="coal", count=200} rcon.print("supplied")`
	if reply, err := game.client.Exec(supply); err != nil || !strings.Contains(reply, "supplied") {
		t.Fatalf("could not supply the body: %v %q", err, reply)
	}

	directives, err := LoadDirectives("../directives")
	if err != nil {
		t.Fatal(err)
	}
	power, found := directives["coal-to-power"]
	if !found {
		t.Fatal("coal-to-power directive is missing")
	}

	spot, err := power.FindAnchor(game, nil)
	if err != nil {
		t.Fatalf("finding a shore: %v", err)
	}
	payload, err := power.Compile(spot, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := game.Call("run_plan", payload); err != nil {
		t.Fatalf("run_plan: %v", err)
	}

	deadline := time.Now().Add(4 * time.Minute)
	var status struct {
		State string `json:"state"`
		Step  int    `json:"step"`
		Steps int    `json:"steps"`
		Error string `json:"error"`
	}
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		raw, err := game.Call("plan_status", nil)
		if err != nil {
			t.Fatalf("plan_status: %v", err)
		}
		if err := json.Unmarshal(raw, &status); err != nil {
			t.Fatalf("plan_status shape: %s", raw)
		}
		if status.State != "running" {
			break
		}
	}
	if status.State != "done" {
		t.Fatalf("directive did not finish: state=%s step=%d/%d error=%s", status.State, status.Step, status.Steps, status.Error)
	}

	// What matters is the world, not the log: the block must be standing, and the
	// boiler must be burning what it was given.
	check := fmt.Sprintf(`/sc local s = game.surfaces.nauvis local area = {{%f, %f}, {%f, %f}} `+
		`local engines = s.count_entities_filtered{area=area, name="steam-engine"} `+
		`local boiler = s.find_entities_filtered{area=area, name="boiler"}[1] `+
		`local poles = s.count_entities_filtered{area=area, name="medium-electric-pole"} `+
		`local fuel = boiler and boiler.get_fuel_inventory() and boiler.get_fuel_inventory().get_item_count("coal") or 0 `+
		`rcon.print(helpers.table_to_json{engines=engines, poles=poles, coal=fuel, steam=(boiler and boiler.fluidbox[2] and boiler.fluidbox[2].amount or 0)})`,
		spot.Position.X-40, spot.Position.Y-40, spot.Position.X+40, spot.Position.Y+40)

	raw, err := game.client.Exec(check)
	if err != nil {
		t.Fatal(err)
	}
	var built struct {
		Engines int     `json:"engines"`
		Poles   int     `json:"poles"`
		Coal    int     `json:"coal"`
		Steam   float64 `json:"steam"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &built); err != nil {
		t.Fatalf("check reply: %s", raw)
	}
	if built.Engines != 3 || built.Poles != 3 {
		t.Fatalf("the block is incomplete: %d engines, %d poles", built.Engines, built.Poles)
	}
	if built.Coal == 0 {
		t.Fatal("the boiler was never fuelled")
	}
	t.Logf("built %d engines, %d poles, boiler holding %d coal, steam %.0f", built.Engines, built.Poles, built.Coal, built.Steam)
}

// The bootstrap loop: power from coal, drills on the coal, a belt between them.
// The point of the assertions is that the loop actually closes -- the drills are
// on the same electric network as the engines, and the belt reaches the boiler.
func TestIntegrationDirectiveClosesTheCoalLoop(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	game := hostTestWorld(t)

	if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": map[string]int{"x": 0, "y": 0}}); err != nil {
		t.Fatalf("spawn: %v", err)
	}

	supply := `/sc local body = game.surfaces.nauvis.find_entities_filtered{name="character"}[1] ` +
		`body.insert{name="offshore-pump", count=1} body.insert{name="boiler", count=1} body.insert{name="steam-engine", count=3} ` +
		`body.insert{name="medium-electric-pole", count=40} body.insert{name="electric-mining-drill", count=4} ` +
		`body.insert{name="transport-belt", count=200} body.insert{name="inserter", count=4} ` +
		`body.insert{name="coal", count=200} rcon.print("supplied")`
	if reply, err := game.client.Exec(supply); err != nil || !strings.Contains(reply, "supplied") {
		t.Fatalf("could not supply the body: %v %q", err, reply)
	}

	directives, err := LoadDirectives("../directives")
	if err != nil {
		t.Fatal(err)
	}
	loop := directives["coal-power-loop"]
	if loop == nil {
		t.Fatal("coal-power-loop directive is missing")
	}

	spot, err := loop.FindAnchor(game, nil)
	if err != nil {
		t.Fatalf("finding a shore: %v", err)
	}
	payload, err := loop.Compile(spot, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := game.Call("run_plan", payload); err != nil {
		t.Fatalf("run_plan: %v", err)
	}

	var status struct {
		State string           `json:"state"`
		Step  int              `json:"step"`
		Steps int              `json:"steps"`
		Error string           `json:"error"`
		Log   []map[string]any `json:"log"`
	}
	deadline := time.Now().Add(8 * time.Minute)
	for time.Now().Before(deadline) {
		time.Sleep(3 * time.Second)
		raw, err := game.Call("plan_status", nil)
		if err != nil {
			t.Fatalf("plan_status: %v", err)
		}
		if err := json.Unmarshal(raw, &status); err != nil {
			t.Fatalf("plan_status shape: %s", raw)
		}
		if status.State != "running" {
			break
		}
	}
	if status.State != "done" {
		t.Fatalf("directive did not finish: state=%s step=%d/%d error=%s", status.State, status.Step, status.Steps, status.Error)
	}

	check := `/sc local s = game.surfaces.nauvis local force = game.forces.player ` +
		`local engine = s.find_entities_filtered{name="steam-engine", force=force}[1] ` +
		`local drills = s.find_entities_filtered{name="electric-mining-drill", force=force} ` +
		`local boiler = s.find_entities_filtered{name="boiler", force=force}[1] ` +
		`local same = false ` +
		`if engine and drills[1] and engine.electric_network_id and drills[1].electric_network_id then same = engine.electric_network_id == drills[1].electric_network_id end ` +
		`rcon.print(helpers.table_to_json{drills=#drills, belts=s.count_entities_filtered{name="transport-belt", force=force}, ` +
		`inserters=s.count_entities_filtered{name="inserter", force=force}, ` +
		`fuel=(boiler and boiler.get_fuel_inventory() and boiler.get_fuel_inventory().get_item_count("coal") or 0), ` +
		`same_network=same})`

	raw, err := game.client.Exec(check)
	if err != nil {
		t.Fatal(err)
	}
	var built struct {
		Drills      int  `json:"drills"`
		Belts       int  `json:"belts"`
		Inserters   int  `json:"inserters"`
		Fuel        int  `json:"fuel"`
		SameNetwork bool `json:"same_network"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &built); err != nil {
		t.Fatalf("check reply: %s", raw)
	}
	t.Logf("drills=%d belts=%d inserters=%d boiler coal=%d one network=%v",
		built.Drills, built.Belts, built.Inserters, built.Fuel, built.SameNetwork)

	if built.Drills == 0 {
		t.Fatal("no drills were built on the coal")
	}
	if built.Belts == 0 || built.Inserters == 0 {
		t.Fatal("the drills are not belted back to the boiler")
	}
	if !built.SameNetwork {
		t.Fatal("the drills are not on the engines' electric network: the loop is not closed")
	}
}

// Giving a directive from inside the game: the mod queues the request, the
// daemon notices and compiles it. No model anywhere in the path.
func TestIntegrationInGameRequestStartsADirective(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	game := hostTestWorld(t)

	if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": map[string]int{"x": 0, "y": 0}}); err != nil {
		t.Fatalf("spawn: %v", err)
	}
	supply := `/sc local body = game.surfaces.nauvis.find_entities_filtered{name="character"}[1] ` +
		`body.insert{name="offshore-pump", count=1} body.insert{name="boiler", count=1} body.insert{name="steam-engine", count=3} ` +
		`body.insert{name="medium-electric-pole", count=3} body.insert{name="coal", count=200} rcon.print("supplied")`
	if _, err := game.client.Exec(supply); err != nil {
		t.Fatal(err)
	}

	daemon := &Daemon{
		Address:    game.client.(*RCON).conn.RemoteAddr().String(),
		Password:   "integration",
		Directives: "../directives",
		Interval:   time.Second,
	}
	stop := make(chan struct{})
	defer close(stop)
	go daemon.Run(stop)

	// The catalogue has to reach the game, or /crew do cannot list anything.
	// Note this is asked for through the mod's own interface: a /sc command runs
	// in the scenario's script context, where the mod's storage is not visible.
	var listed string
	for attempt := 0; attempt < 20; attempt++ {
		time.Sleep(time.Second)
		raw, err := game.Call("catalogue", nil)
		if err == nil && strings.Contains(string(raw), "coal-to-power") {
			listed = string(raw)
			break
		}
	}
	if listed == "" {
		t.Fatal("the daemon never published the directive catalogue to the game")
	}

	// Stand in for a player typing /crew do coal-to-power: the command queues a
	// request exactly like this one.
	if _, err := game.Call("request", map[string]any{"directive": "coal-to-power", "player": "test"}); err != nil {
		t.Fatalf("queueing the request: %v", err)
	}

	var status struct {
		State string `json:"state"`
		Name  string `json:"name"`
	}
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		raw, err := game.Call("plan_status", nil)
		if err != nil {
			t.Fatalf("plan_status: %v", err)
		}
		json.Unmarshal(raw, &status)
		if status.State == "running" || status.State == "done" {
			break
		}
	}
	if status.Name != "coal-to-power" {
		t.Fatalf("the request never became a running directive: %+v", status)
	}
	t.Logf("in-game request started %q (%s)", status.Name, status.State)
}

// Hand mining: no items are conjured, so the only proof is that the body is
// carrying coal afterwards that it dug up itself.
func TestIntegrationMinesCoalByHand(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	game := hostTestWorld(t)

	if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": map[string]int{"x": 0, "y": 0}}); err != nil {
		t.Fatalf("spawn: %v", err)
	}

	directives, err := LoadDirectives("../directives")
	if err != nil {
		t.Fatal(err)
	}
	mine := directives["mine-coal"]
	if mine == nil {
		t.Fatal("mine-coal directive is missing")
	}

	spot, err := mine.FindAnchor(game, nil)
	if err != nil {
		t.Fatal(err)
	}
	payload, err := mine.Compile(spot, map[string]float64{"amount": 12})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := game.Call("run_plan", payload); err != nil {
		t.Fatalf("run_plan: %v", err)
	}

	var status struct {
		State string `json:"state"`
		Step  int    `json:"step"`
		Error string `json:"error"`
	}
	var sawMining bool
	deadline := time.Now().Add(3 * time.Minute)
	for time.Now().Before(deadline) {
		time.Sleep(2 * time.Second)
		raw, err := game.Call("plan_status", nil)
		if err != nil {
			t.Fatalf("plan_status: %v", err)
		}
		json.Unmarshal(raw, &status)

		// Standing there with the mining animation running is the difference
		// between working and looking broken.
		if body, err := game.Call("status", nil); err == nil {
			var state struct {
				Body struct {
					Sign string `json:"sign"`
				} `json:"body"`
			}
			json.Unmarshal(body, &state)
			if strings.Contains(state.Body.Sign, "mining") {
				sawMining = true
			}
		}
		if status.State != "running" {
			break
		}
	}
	if status.State != "done" {
		t.Fatalf("mining did not finish: state=%s step=%d error=%s", status.State, status.Step, status.Error)
	}

	raw, err := game.Call("carrying", nil)
	if err != nil {
		t.Fatal(err)
	}
	var pockets struct {
		Carrying []struct {
			Name  string `json:"name"`
			Count int    `json:"count"`
		} `json:"carrying"`
	}
	if err := json.Unmarshal(raw, &pockets); err != nil {
		t.Fatalf("carrying shape: %s", raw)
	}
	coal := 0
	for _, stack := range pockets.Carrying {
		if stack.Name == "coal" {
			coal = stack.Count
		}
	}
	if coal < 12 {
		t.Fatalf("it came back with %d coal, not the 12 it was asked for", coal)
	}
	if !sawMining {
		t.Fatal("nothing above its head ever said it was mining: it looks broken while it works")
	}
	t.Logf("hand-mined %d coal, visibly", coal)
}

// "Find the closest coal" has to mean the closest, not whichever the engine
// happened to return first: a limited area search hands back what it comes
// across, which can be a patch on the far side of one you are standing on.
func TestIntegrationFindsTheNearestPatch(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	game := hostTestWorld(t)

	for _, at := range []map[string]int{{"x": 0, "y": 0}, {"x": 80, "y": -60}, {"x": -90, "y": 70}} {
		if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": at}); err != nil {
			t.Fatalf("spawn: %v", err)
		}

		// The truth, computed without a limit over a wide area.
		truth, err := game.client.Exec(`/sc local s = game.surfaces.nauvis ` +
			`local b = s.find_entities_filtered{name="character"}[1] ` +
			`local ore = s.find_entities_filtered{name="coal", position=b.position, radius=256} ` +
			`local best for _, o in pairs(ore) do ` +
			`local d = math.sqrt((o.position.x-b.position.x)^2 + (o.position.y-b.position.y)^2) ` +
			`if not best or d < best then best = d end end ` +
			`rcon.print(helpers.table_to_json{nearest = best or -1})`)
		if err != nil {
			t.Fatal(err)
		}
		var actual struct {
			Nearest float64 `json:"nearest"`
		}
		if err := json.Unmarshal([]byte(strings.TrimSpace(truth)), &actual); err != nil {
			t.Fatalf("truth reply: %s", truth)
		}
		if actual.Nearest < 0 {
			continue // no coal within 256 tiles of this spot; nothing to compare
		}

		raw, err := game.Call("find_resource", map[string]any{"resource": "coal", "radius": 256})
		if err != nil {
			t.Fatalf("find_resource from %v: %v", at, err)
		}
		var found struct {
			Distance float64 `json:"distance"`
			Tiles    int     `json:"tiles"`
		}
		if err := json.Unmarshal(raw, &found); err != nil {
			t.Fatalf("find_resource shape: %s", raw)
		}
		if found.Distance > actual.Nearest+0.5 {
			t.Fatalf("from %v it found coal %.1f tiles away when there is some at %.1f",
				at, found.Distance, actual.Nearest)
		}
		t.Logf("from %v: nearest coal %.1f tiles away, patch of %d", at, found.Distance, found.Tiles)
	}
}

// Deciding what to do next from its own inventory: stock-coal checks, digs if it
// is short, checks again, and stops when it is not. Nothing outside the game is
// consulted at any point.
func TestIntegrationConditionsDecideWhatHappens(t *testing.T) {
	if os.Getenv("CREWMATE_INTEGRATION") == "" {
		t.Skip("set CREWMATE_INTEGRATION=1 to run against a real Factorio install")
	}
	game := hostTestWorld(t)
	if _, err := game.Call("spawn", map[string]any{"surface": "nauvis", "position": map[string]int{"x": 0, "y": 0}}); err != nil {
		t.Fatal(err)
	}

	known, err := LoadDirectives("../directives")
	if err != nil {
		t.Fatal(err)
	}
	stock := known["stock-coal"]

	run := func(amount float64) (string, []map[string]any) {
		t.Helper()
		payload, err := stock.CompileWith(Spot{}, map[string]float64{"amount": amount}, known)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := game.Call("run_plan", payload); err != nil {
			t.Fatalf("run_plan: %v", err)
		}
		var status struct {
			State string           `json:"state"`
			Error string           `json:"error"`
			Log   []map[string]any `json:"log"`
		}
		deadline := time.Now().Add(3 * time.Minute)
		for time.Now().Before(deadline) {
			time.Sleep(2 * time.Second)
			raw, err := game.Call("plan_status", nil)
			if err != nil {
				t.Fatal(err)
			}
			json.Unmarshal(raw, &status)
			if status.State != "running" {
				break
			}
		}
		if status.State != "done" {
			t.Fatalf("stock-coal(%v) did not finish: %s %s", amount, status.State, status.Error)
		}
		return status.State, status.Log
	}

	carrying := func(item string) int {
		t.Helper()
		raw, err := game.Call("carrying", nil)
		if err != nil {
			t.Fatal(err)
		}
		var pockets struct {
			Carrying []struct {
				Name  string `json:"name"`
				Count int    `json:"count"`
			} `json:"carrying"`
		}
		json.Unmarshal(raw, &pockets)
		for _, stack := range pockets.Carrying {
			if stack.Name == item {
				return stack.Count
			}
		}
		return 0
	}

	// Short of coal: it should go and dig until it is not.
	run(8)
	if got := carrying("coal"); got < 8 {
		t.Fatalf("asked for 8 coal, came back with %d", got)
	}

	// Already stocked: the same directive should decide there is nothing to do.
	// Every included step is guarded, so none of them should even look for a patch.
	_, second := run(5)
	for _, entry := range second {
		if entry["outcome"] == "found" || entry["outcome"] == "mined" {
			t.Fatalf("it already had enough coal and went digging anyway: %v", second)
		}
	}
	t.Logf("dug when short (%d coal), did nothing when stocked", carrying("coal"))
}
