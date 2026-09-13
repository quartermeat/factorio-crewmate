package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// A personality is data too: a research bias and what it does with itself when
// nobody has asked for anything. The bridge only carries these to the game; every
// decision they lead to is made in the mod, on the game's clock.
type Personality struct {
	Name           string            `json:"name"`
	Title          string            `json:"title"`
	Description    string            `json:"description"`
	ResearchPath   []string          `json:"research_path"`
	StandingOrders []json.RawMessage `json:"standing_orders"`
	Volunteers     []string          `json:"volunteers"`
	Voice          map[string]string `json:"voice"`
}

func LoadPersonalities(directory string) (map[string]*Personality, error) {
	entries, err := os.ReadDir(directory)
	if err != nil {
		return nil, fmt.Errorf("no personalities at %s: %w", directory, err)
	}
	loaded := map[string]*Personality{}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		contents, err := os.ReadFile(filepath.Join(directory, entry.Name()))
		if err != nil {
			return nil, err
		}
		var personality Personality
		if err := json.Unmarshal(contents, &personality); err != nil {
			return nil, fmt.Errorf("%s: %w", entry.Name(), err)
		}
		if personality.Name == "" {
			return nil, fmt.Errorf("%s: a personality needs a name", entry.Name())
		}
		loaded[personality.Name] = &personality
	}
	return loaded, nil
}
