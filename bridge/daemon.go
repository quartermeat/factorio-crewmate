package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// The game cannot read the directive files, so /crew do leaves a request behind
// and this picks it up. It is a plain polling loop on purpose: giving a directive
// from inside the game costs nothing but the electricity, and never needs a model
// in the middle of it.
type Daemon struct {
	Address    string
	Password   string
	Directives string
	Interval   time.Duration
}

func (d *Daemon) Run(stop <-chan struct{}) {
	interval := d.Interval
	if interval == 0 {
		interval = 2 * time.Second
	}
	for {
		select {
		case <-stop:
			return
		default:
		}
		game, err := d.connect()
		if err != nil {
			select {
			case <-stop:
				return
			case <-time.After(interval):
				continue
			}
		}
		d.serve(game, stop, interval)
	}
}

func (d *Daemon) connect() (*Game, error) {
	client, err := Dial(d.Address, d.Password, 5*time.Second)
	if err != nil {
		return nil, err
	}
	game := &Game{client: client}
	if err := d.publishCatalogue(game); err != nil {
		client.Close()
		return nil, err
	}
	return game, nil
}

// Tell the game what it can be asked for, so /crew do can list directives
// without the mod ever touching a file.
func (d *Daemon) publishCatalogue(game *Game) error {
	known, err := LoadDirectives(d.Directives)
	if err != nil {
		return err
	}
	listed := make([]map[string]any, 0, len(known))
	for _, directive := range known {
		listed = append(listed, map[string]any{"name": directive.Name, "title": directive.Title})
	}
	if _, err := game.Call("set_catalogue", map[string]any{"directives": listed}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "crewmate: watching for /crew do, %d directives loaded\n", len(listed))
	return nil
}

func (d *Daemon) serve(game *Game, stop <-chan struct{}, interval time.Duration) {
	defer func() {
		if closer, ok := game.client.(*RCON); ok {
			closer.Close()
		}
	}()
	for {
		select {
		case <-stop:
			return
		case <-time.After(interval):
		}

		raw, err := game.Call("take_requests", nil)
		if err != nil {
			return // the server has probably gone; Run will reconnect
		}
		var pending struct {
			Requests []struct {
				Directive string `json:"directive"`
				Player    string `json:"player"`
			} `json:"requests"`
		}
		if err := json.Unmarshal(raw, &pending); err != nil {
			continue
		}
		for _, request := range pending.Requests {
			if err := d.start(game, request.Directive); err != nil {
				fmt.Fprintf(os.Stderr, "crewmate: %s: %v\n", request.Directive, err)
				game.Call("say", map[string]any{"message": "I cannot do that: " + err.Error()})
			}
		}
	}
}

func (d *Daemon) start(game *Game, name string) error {
	known, err := LoadDirectives(d.Directives)
	if err != nil {
		return err
	}
	chosen, found := known[name]
	if !found {
		return fmt.Errorf("I do not know a directive called %q", name)
	}

	spot, err := chosen.FindAnchor(game, nil)
	if err != nil {
		return err
	}
	payload, err := chosen.Compile(spot, nil)
	if err != nil {
		return err
	}
	if _, err := game.Call("run_plan", payload); err != nil {
		return err
	}
	return nil
}
