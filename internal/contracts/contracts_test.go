package contracts

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/samay-app/samay/internal/db"
)

type fixture struct {
	Name   string            `json:"name"`
	Source string            `json:"source"`
	Fields map[string]string `json:"fields"`
	Enums  map[string][]any  `json:"enums"`
	Sample []map[string]any  `json:"samples"`
	Codes  []string          `json:"codes"`
	HTTP   map[string]int    `json:"http"`
}

const dir = "../../test/contracts"

func load(t *testing.T) []fixture {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(dir, "*.contract.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatalf("no contract fixtures in %s", dir)
	}
	sort.Strings(paths)
	out := make([]fixture, 0, len(paths))
	for _, p := range paths {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		var f fixture
		if err := json.Unmarshal(raw, &f); err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		if f.Name == "" || f.Source == "" {
			t.Fatalf("%s: name and source are required", p)
		}
		out = append(out, f)
	}
	return out
}

func TestFixtures(t *testing.T) {
	for _, f := range load(t) {
		f := f
		t.Run(f.Name, func(t *testing.T) {
			if len(f.Fields) > 0 {
				validateShapes(t, f)
			}
			if len(f.Codes) > 0 {
				validateCodes(t, f)
			}
		})
	}
}

func validateShapes(t *testing.T, f fixture) {
	t.Helper()
	if len(f.Sample) == 0 {
		t.Fatalf("no samples")
	}
	for i, s := range f.Sample {
		if got, want := len(s), len(f.Fields); got != want {
			t.Fatalf("sample %d has %d keys, want %d (frozen shape)", i, got, want)
		}
		for k, expr := range f.Fields {
			v, ok := s[k]
			if !ok {
				t.Fatalf("sample %d missing field %q", i, k)
			}
			if err := checkType(k, expr, v); err != nil {
				t.Fatalf("sample %d: %v", i, err)
			}
			if v == nil {
				continue
			}
			if allowed, ok := f.Enums[k]; ok && !contains(allowed, v) {
				t.Fatalf("sample %d: %q = %v not in enum %v", i, k, v, allowed)
			}
		}
	}
}

func checkType(name, expr string, v any) error {
	if v == nil {
		if !hasType(expr, "null") {
			return &typeError{name, expr, "non-null"}
		}
		return nil
	}
	switch v.(type) {
	case string:
		if !hasType(expr, "string") && !hasType(expr, "date") {
			return &typeError{name, expr, "string"}
		}
		if hasType(expr, "date") {
			if _, err := time.Parse(time.RFC3339, v.(string)); err != nil {
				return &typeError{name, expr, "RFC3339 string"}
			}
		}
	case bool:
		if !hasType(expr, "boolean") {
			return &typeError{name, expr, "boolean"}
		}
	case float64:
		if hasType(expr, "integer") && math.Trunc(v.(float64)) != v.(float64) {
			return &typeError{name, expr, "integer"}
		}
		if !hasType(expr, "number") && !hasType(expr, "integer") {
			return &typeError{name, expr, "number"}
		}
	case map[string]any:
		if !hasType(expr, "object") {
			return &typeError{name, expr, "object"}
		}
	case []any:
		if !hasType(expr, "array") {
			return &typeError{name, expr, "array"}
		}
	default:
		return &typeError{name, expr, "unknown value type"}
	}
	return nil
}

type typeError struct{ name, expr, got string }

func (e *typeError) Error() string {
	return e.name + ": " + e.expr + " cannot hold " + e.got
}

func hasType(expr, want string) bool {
	for _, p := range strings.Split(expr, "|") {
		if strings.TrimSpace(p) == want {
			return true
		}
	}
	return false
}

func contains(allowed []any, v any) bool {
	for _, a := range allowed {
		if reflect.DeepEqual(a, v) {
			return true
		}
	}
	return false
}

func validateCodes(t *testing.T, f fixture) {
	t.Helper()
	seen := map[string]bool{}
	for _, c := range f.Codes {
		if c == "" || seen[c] {
			t.Fatalf("empty or duplicate code %q", c)
		}
		seen[c] = true
	}
	for c, status := range f.HTTP {
		if !seen[c] {
			t.Fatalf("http mapping for unknown code %q", c)
		}
		if status < 100 || status > 599 {
			t.Fatalf("code %q has invalid status %d", c, status)
		}
	}
}

// The admin handlers must emit exactly the frozen tag set.
func TestAdminStructShapes(t *testing.T) {
	byName := map[string]fixture{}
	for _, f := range load(t) {
		byName[f.Name] = f
	}
	cases := []struct {
		name string
		typ  any
	}{
		{"admin_event", db.Event{}},
		{"admin_user", db.User{}},
	}
	for _, c := range cases {
		f, ok := byName[c.name]
		if !ok {
			t.Fatalf("missing %s fixture", c.name)
		}
		tags := jsonTags(reflect.TypeOf(c.typ))
		if want, got := sortedKeys(f.Fields), tags; !reflect.DeepEqual(want, got) {
			t.Fatalf("%s fixture keys %v != Go json tags %v (update both)", c.name, want, got)
		}
	}
}

func jsonTags(t reflect.Type) []string {
	out := make([]string, 0, t.NumField())
	for i := 0; i < t.NumField(); i++ {
		tag := strings.Split(t.Field(i).Tag.Get("json"), ",")[0]
		if tag == "" || tag == "-" {
			continue
		}
		out = append(out, tag)
	}
	sort.Strings(out)
	return out
}

func sortedKeys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
