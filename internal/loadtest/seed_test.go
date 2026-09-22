package loadtest

import (
	"math/rand"
	"testing"
)

func TestFriendshipEdges(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	edges := FriendshipEdges(100, 300, r)
	if len(edges) != 300 {
		t.Fatalf("edges = %d, want 300", len(edges))
	}
	seen := map[[2]int]bool{}
	for _, e := range edges {
		if e[0] < 0 || e[0] >= 100 || e[1] < 0 || e[1] >= 100 {
			t.Fatalf("edge out of range: %v", e)
		}
		if e[0] == e[1] {
			t.Fatalf("self edge: %v", e)
		}
		key := e
		if key[0] > key[1] {
			key[0], key[1] = key[1], key[0]
		}
		if seen[key] {
			t.Fatalf("duplicate edge: %v", e)
		}
		seen[key] = true
	}
	// deterministic
	again := FriendshipEdges(100, 300, rand.New(rand.NewSource(1)))
	for i := range edges {
		if edges[i] != again[i] {
			t.Fatalf("not deterministic at %d: %v vs %v", i, edges[i], again[i])
		}
	}
}

func TestFriendshipEdgesImpossible(t *testing.T) {
	// more edges than possible pairs → capped, no panic/infinite loop.
	edges := FriendshipEdges(3, 100, rand.New(rand.NewSource(2)))
	if len(edges) > 3 {
		t.Fatalf("expected at most 3 unique edges, got %d", len(edges))
	}
}

func TestPlanMatches(t *testing.T) {
	plans := PlanMatches(100, 15, rand.New(rand.NewSource(3)))
	if len(plans) != 100 {
		t.Fatalf("plans = %d, want 100", len(plans))
	}
	types := map[string]int{}
	states := map[string]int{}
	modes := map[string]int{}
	for _, p := range plans {
		types[p.GameType]++
		states[p.State]++
		modes[p.Mode]++
		if p.GroupID < -1 || p.GroupID >= 15 {
			t.Fatalf("group id out of range: %d", p.GroupID)
		}
		if p.Players < 2 {
			t.Fatalf("players < 2: %d", p.Players)
		}
	}
	for _, want := range []string{"truth_dare", "drunk_bottle", "two_lies_one_truth", "charades"} {
		if types[want] == 0 {
			t.Errorf("missing game type %q", want)
		}
	}
	for _, want := range []string{"lobby", "countdown", "playing", "finished"} {
		if states[want] == 0 {
			t.Errorf("missing state %q", want)
		}
	}
	if modes["async"] == 0 || modes["by_turns"] == 0 {
		t.Errorf("modes = %v", modes)
	}
}

func TestPlanMatchesDeterministic(t *testing.T) {
	a := PlanMatches(50, 10, rand.New(rand.NewSource(9)))
	b := PlanMatches(50, 10, rand.New(rand.NewSource(9)))
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("not deterministic at %d", i)
		}
	}
}

func TestPickWeighted(t *testing.T) {
	weights := []int{1, 2, 3}
	cases := []struct {
		r    int
		want int
	}{
		{0, 0}, {1, 1}, {2, 1}, {3, 2}, {4, 2}, {5, 2},
	}
	for _, c := range cases {
		if got := PickWeighted(weights, c.r); got != c.want {
			t.Errorf("PickWeighted(%v, %d) = %d, want %d", weights, c.r, got, c.want)
		}
	}
	// out-of-range r still returns a valid index (lenient wrap).
	if got := PickWeighted(weights, 999); got < 0 || got >= len(weights) {
		t.Errorf("PickWeighted out-of-range = %d", got)
	}
}

func TestCapMembers(t *testing.T) {
	cases := []struct{ desired, users, want int }{
		{13, 3, 3},
		{2, 100, 2},
		{100, 100, 100},
		{-1, 5, 0},
		{5, 0, 0},
	}
	for _, c := range cases {
		if got := capMembers(c.desired, c.users); got != c.want {
			t.Errorf("capMembers(%d,%d) = %d, want %d", c.desired, c.users, got, c.want)
		}
	}
}

func TestChunk(t *testing.T) {
	got := chunk(10, 3)
	if len(got) != 4 || got[0] != 3 || got[3] != 1 {
		t.Fatalf("chunk(10,3) = %v", got)
	}
	if got := chunk(0, 3); len(got) != 0 {
		t.Fatalf("chunk(0,3) = %v", got)
	}
	// never exceeds the limit
	for _, n := range chunk(100, 7) {
		if n > 7 {
			t.Fatalf("chunk size %d > 7", n)
		}
	}
}
