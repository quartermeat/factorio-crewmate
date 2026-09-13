package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func load(t *testing.T) map[string]*Directive {
	t.Helper()
	known, err := LoadDirectives("../directives")
	if err != nil {
		t.Fatal(err)
	}
	return known
}

// include pulls another directive's steps in where it stands, so a small job can
// be reused rather than copied.
func TestIncludeExpandsTheOtherDirective(t *testing.T) {
	known := load(t)
	stock := known["stock-coal"]
	if stock == nil {
		t.Fatal("stock-coal is missing")
	}

	payload, err := stock.CompileWith(Spot{}, nil, known)
	if err != nil {
		t.Fatal(err)
	}
	steps := payload["steps"].([]map[string]any)

	var verbs []string
	for _, step := range steps {
		verbs = append(verbs, step["do"].(string))
	}
	joined := strings.Join(verbs, ",")
	if strings.Contains(joined, "include") {
		t.Fatalf("include should not survive compilation: %s", joined)
	}
	if !strings.Contains(joined, "mine") {
		t.Fatalf("mine-coal's steps did not come through: %s", joined)
	}
}

// A value written as "$something" at an include site keeps pointing at the
// including directive's parameter, so numbers flow down.
func TestIncludeForwardsParameters(t *testing.T) {
	known := load(t)
	payload, err := known["stock-coal"].CompileWith(Spot{}, map[string]float64{"amount": 250}, known)
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range payload["steps"].([]map[string]any) {
		if step["do"] == "mine" {
			if step["amount"] != float64(250) {
				t.Fatalf("mine step got amount %v, not the 250 asked for", step["amount"])
			}
			return
		}
	}
	t.Fatal("no mine step in the compiled directive")
}

// The condition on an include has to guard everything it brought in, or a
// directive that is already stocked would go mining anyway.
func TestIncludeConditionGuardsIncludedSteps(t *testing.T) {
	known := load(t)
	payload, err := known["stock-coal"].CompileWith(Spot{}, nil, known)
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range payload["steps"].([]map[string]any) {
		if step["do"] == "mine" || step["do"] == "find_resource" {
			condition, carried := step["when"].(map[string]any)
			if !carried {
				t.Fatalf("%s came in without the include's condition", step["do"])
			}
			encoded, _ := json.Marshal(condition)
			if !strings.Contains(string(encoded), "carrying") {
				t.Fatalf("wrong condition carried onto %s: %s", step["do"], encoded)
			}
		}
	}
}

func TestDirectivesAllValidate(t *testing.T) {
	known := load(t)
	if len(known) < 4 {
		t.Fatalf("expected the shipped directives to load, got %d", len(known))
	}
	for name, directive := range known {
		if _, err := directive.CompileWith(Spot{}, nil, known); err != nil {
			t.Errorf("%s does not compile: %v", name, err)
		}
	}
}
