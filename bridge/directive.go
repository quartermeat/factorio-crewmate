package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// A directive is a goal written down: what to build, where it has to go, what it
// costs, and the steps to get there. The mod cannot read files -- Factorio gives
// runtime scripts no way to -- so directives live out here and arrive at the game
// already resolved into absolute positions and numbers.
type Directive struct {
	Name        string               `json:"name"`
	Title       string               `json:"title"`
	Description string               `json:"description"`
	Anchor      Anchor               `json:"anchor"`
	Blueprint   string               `json:"blueprint"`
	Align       string               `json:"align"`
	Parameters  map[string]Parameter `json:"parameters"`
	Supplies    []json.RawMessage    `json:"supplies"`
	Steps       []map[string]any     `json:"steps"`
}

type Anchor struct {
	Find     string `json:"find"`     // "pump_spot", or "" to use Near directly
	Near     string `json:"near"`     // "player" or "body"
	Radius   int    `json:"radius"`   //
	Describe string `json:"describe"` // what the spot is, for explaining a failure
}

type Parameter struct {
	Default     float64 `json:"default"`
	Description string  `json:"description"`
}

type Spot struct {
	Position  Point `json:"position"`
	Direction int   `json:"direction"`
}

type Point struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

func LoadDirectives(directory string) (map[string]*Directive, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, fmt.Errorf("no directives at %s: %w", directory, err)
	}
	loaded := map[string]*Directive{}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		contents, err := os.ReadFile(filepath.Join(directory, entry.Name()))
		if err != nil {
			return nil, err
		}
		var directive Directive
		if err := json.Unmarshal(contents, &directive); err != nil {
			return nil, fmt.Errorf("%s: %w", entry.Name(), err)
		}
		if err := directive.validate(); err != nil {
			return nil, fmt.Errorf("%s: %w", entry.Name(), err)
		}
		loaded[directive.Name] = &directive
	}
	return loaded, nil
}

func (d *Directive) validate() error {
	if d.Name == "" {
		return fmt.Errorf("a directive needs a name")
	}
	if len(d.Steps) == 0 {
		return fmt.Errorf("%s has no steps", d.Name)
	}
	for index, step := range d.Steps {
		verb, _ := step["do"].(string)
		switch verb {
		case "say", "goto", "stamp", "build_ghosts", "insert", "place", "connect", "wait",
			"find_resource", "find_site", "drill_row", "belt_line", "pole_line", "check_power", "mine":
		case "":
			return fmt.Errorf("step %d has no \"do\"", index+1)
		default:
			return fmt.Errorf("step %d: nothing knows how to %q", index+1, verb)
		}
		if verb == "stamp" && d.Blueprint == "" {
			return fmt.Errorf("step %d stamps a blueprint but the directive has none", index+1)
		}
	}
	return nil
}

// Values may be written as "$parameter" anywhere a number belongs.
func (d *Directive) resolve(value any, parameters map[string]float64) any {
	switch typed := value.(type) {
	case string:
		if name, found := strings.CutPrefix(typed, "$"); found {
			if resolved, known := parameters[name]; known {
				return resolved
			}
		}
		return typed
	case map[string]any:
		for key, nested := range typed {
			typed[key] = d.resolve(nested, parameters)
		}
		return typed
	case []any:
		for index, nested := range typed {
			typed[index] = d.resolve(nested, parameters)
		}
		return typed
	default:
		return value
	}
}

func (d *Directive) settings(overrides map[string]float64) map[string]float64 {
	values := map[string]float64{}
	for name, parameter := range d.Parameters {
		values[name] = parameter.Default
	}
	for name, value := range overrides {
		values[name] = value
	}
	return values
}

// Compile turns the directive into the payload run_plan expects: steps with real
// coordinates, the blueprint attached to the step that stamps it, and the
// supplies the body must already be carrying.
func (d *Directive) Compile(anchor Spot, overrides map[string]float64) (map[string]any, error) {
	parameters := d.settings(overrides)

	steps := make([]map[string]any, 0, len(d.Steps))
	for _, original := range d.Steps {
		step := map[string]any{}
		for key, value := range original {
			step[key] = value
		}
		if step["at"] == "anchor" {
			delete(step, "at")
			step["x"], step["y"] = anchor.Position.X, anchor.Position.Y
			step["direction"] = directionName(anchor.Direction)
		}
		if verb, _ := step["do"].(string); verb == "stamp" {
			step["blueprint"] = d.Blueprint
			if d.Align != "" && step["entity"] == nil {
				step["entity"] = d.Align
			}
		}
		for key, value := range step {
			step[key] = d.resolve(value, parameters)
		}
		steps = append(steps, step)
	}

	supplies := []map[string]any{}
	for _, raw := range d.Supplies {
		var supply map[string]any
		if err := json.Unmarshal(raw, &supply); err != nil {
			return nil, err
		}
		for key, value := range supply {
			supply[key] = d.resolve(value, parameters)
		}
		supplies = append(supplies, supply)
	}

	return map[string]any{
		"name":     d.Name,
		"steps":    steps,
		"requires": supplies,
	}, nil
}

var directionNames = map[int]string{0: "north", 4: "east", 8: "south", 12: "west"}

func directionName(direction int) string {
	if name, known := directionNames[direction]; known {
		return name
	}
	return "north"
}

// FindAnchor asks the game where this directive could actually happen.
func (d *Directive) FindAnchor(game *Game, at *Point) (Spot, error) {
	if at != nil {
		return Spot{Position: *at}, nil
	}
	switch d.Anchor.Find {
	case "pump_spot":
		radius := d.Anchor.Radius
		if radius == 0 {
			radius = 64
		}
		raw, err := game.Call("pump_spots", map[string]any{"radius": radius, "limit": 1})
		if err != nil {
			return Spot{}, err
		}
		var found struct {
			Spots []Spot `json:"spots"`
		}
		if err := json.Unmarshal(raw, &found); err != nil {
			return Spot{}, err
		}
		if len(found.Spots) == 0 {
			describe := d.Anchor.Describe
			if describe == "" {
				describe = "a suitable spot"
			}
			return Spot{}, fmt.Errorf("I cannot find %s within %d tiles", describe, radius)
		}
		return found.Spots[0], nil
	case "":
		raw, err := game.Call("status", nil)
		if err != nil {
			return Spot{}, err
		}
		var status struct {
			Body struct {
				Position Point `json:"position"`
			} `json:"body"`
		}
		if err := json.Unmarshal(raw, &status); err != nil {
			return Spot{}, err
		}
		return Spot{Position: status.Body.Position}, nil
	default:
		return Spot{}, fmt.Errorf("no way to find %q", d.Anchor.Find)
	}
}

func (d *Directive) Summary() string {
	parameters := make([]string, 0, len(d.Parameters))
	for name, parameter := range d.Parameters {
		parameters = append(parameters, fmt.Sprintf("%s=%s", name, strconv.FormatFloat(parameter.Default, 'f', -1, 64)))
	}
	sort.Strings(parameters)
	line := fmt.Sprintf("%-16s %s", d.Name, d.Title)
	if len(parameters) > 0 {
		line += " (" + strings.Join(parameters, ", ") + ")"
	}
	return line
}
