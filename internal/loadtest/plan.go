package loadtest

import "math/rand"

// gameTypes are the four fully-plugged minigame types.
var gameTypes = []string{"truth_dare", "drunk_bottle", "two_lies_one_truth", "charades"}

// MatchPlan describes how one seeded minigame match should be created.
type MatchPlan struct {
	GameType string
	State    string // lobby | countdown | playing | finished
	Mode     string // by_turns | async
	GroupID  int    // -1 = direct session
	Public   bool
	Players  int
}

// PlanMatches lays out total matches across game types and lifecycle states,
// guaranteeing coverage of every game type and every state, deterministically
// for a given rng.
func PlanMatches(total, groupCount int, rng *rand.Rand) []MatchPlan {
	if total <= 0 {
		return nil
	}
	states := stateDeck(total, rng)
	plans := make([]MatchPlan, 0, total)
	for i := 0; i < total; i++ {
		gt := gameTypes[i%len(gameTypes)]
		mode := "by_turns"
		if allowsAsync(gt) && rng.Intn(10) < 3 {
			mode = "async"
		}
		groupID := -1
		if groupCount > 0 && rng.Intn(10) < 5 {
			groupID = rng.Intn(groupCount)
		}
		public := groupID == -1 && rng.Intn(5) == 0
		players := 2 + rng.Intn(5) // 2..6, inside the free-tier cap of 8
		plans = append(plans, MatchPlan{
			GameType: gt,
			State:    states[i],
			Mode:     mode,
			GroupID:  groupID,
			Public:   public,
			Players:  players,
		})
	}
	return plans
}

// allowsAsync reports whether a game type supports the async play mode.
func allowsAsync(gameType string) bool {
	switch gameType {
	case "truth_dare", "two_lies_one_truth":
		return true
	default:
		return false
	}
}

// stateDeck returns total lifecycle states with all four represented and
// shuffled deterministically.
func stateDeck(total int, rng *rand.Rand) []string {
	finished := total * 45 / 100
	playing := total * 30 / 100
	lobby := total * 13 / 100
	countdown := total - finished - playing - lobby
	if countdown < 1 && total >= 4 {
		countdown = 1
		finished -= 1
	}
	deck := make([]string, 0, total)
	add := func(state string, n int) {
		for i := 0; i < n; i++ {
			deck = append(deck, state)
		}
	}
	add("finished", finished)
	add("playing", playing)
	add("lobby", lobby)
	add("countdown", countdown)
	for len(deck) < total { // rounding top-up
		deck = append(deck, "playing")
	}
	if len(deck) > total {
		deck = deck[:total]
	}
	rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
	return deck
}

// FriendshipEdges generates up to edges unique undirected pairs among users.
func FriendshipEdges(users, edges int, rng *rand.Rand) [][2]int {
	if users < 2 || edges <= 0 {
		return nil
	}
	possible := users * (users - 1) / 2
	if edges > possible {
		edges = possible
	}
	seen := make(map[[2]int]bool, edges)
	out := make([][2]int, 0, edges)
	attempts := 0
	maxAttempts := edges*50 + users*10
	for len(out) < edges && attempts < maxAttempts {
		attempts++
		a, b := rng.Intn(users), rng.Intn(users)
		if a == b {
			continue
		}
		key := [2]int{a, b}
		if key[0] > key[1] {
			key[0], key[1] = key[1], key[0]
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, [2]int{a, b})
	}
	return out
}

// PickWeighted selects an index from weights for a value in [0, sum(weights)).
// Out-of-range values wrap; negative weights are treated as zero.
func PickWeighted(weights []int, r int) int {
	total := 0
	for _, w := range weights {
		if w > 0 {
			total += w
		}
	}
	if total <= 0 {
		return 0
	}
	r %= total
	if r < 0 {
		r += total
	}
	acc := 0
	for i, w := range weights {
		if w <= 0 {
			continue
		}
		acc += w
		if r < acc {
			return i
		}
	}
	return len(weights) - 1
}

// chunk splits total into consecutive groups of at most size.
func chunk(total, size int) []int {
	if total <= 0 || size <= 0 {
		return nil
	}
	var out []int
	for total > 0 {
		n := size
		if n > total {
			n = total
		}
		out = append(out, n)
		total -= n
	}
	return out
}
