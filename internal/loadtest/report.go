package loadtest

import (
	"fmt"
	"time"

	"github.com/samay-app/samay/internal/format"
)

// Report is the full outcome of a harness run.
type Report struct {
	URL          string          `json:"url"`
	RunID        string          `json:"run_id"`
	StartedAt    time.Time       `json:"started_at"`
	Duration     time.Duration   `json:"duration_ns"`
	Seed         *SeedResult     `json:"seed,omitempty"`
	Load         []OpStats       `json:"load,omitempty"`
	Realtime     *RealtimeResult `json:"realtime,omitempty"`
	TotalOps     int64           `json:"total_ops"`
	TotalErrors  int64           `json:"total_errors"`
	ErrorRate    float64         `json:"error_rate"`
	MaxErrorRate float64         `json:"max_error_rate"`
	Passed       bool            `json:"passed"`
}

// Render writes the report to stdout either as a table or as JSON.
func (r *Report) Render(jsonOut bool) {
	if jsonOut {
		format.RenderJSON(r)
		return
	}
	fmt.Println()
	fmt.Println("═══════════════════════════════════════════════════════════════")
	fmt.Println("  Samay load test report")
	fmt.Println("═══════════════════════════════════════════════════════════════")
	fmt.Printf("  target   : %s\n", r.URL)
	fmt.Printf("  run-id   : %s\n", r.RunID)
	fmt.Printf("  elapsed  : %s\n", r.Duration.Round(time.Millisecond))

	if r.Seed != nil {
		s := r.Seed
		fmt.Println()
		fmt.Println("── seed ──────────────────────────────────────────────────────")
		fmt.Printf("  users=%d avatars=%d friendships=%d groups=%d (banners=%d, members=%d)\n",
			s.Users, s.Avatars, s.Friendships, s.Groups, s.GroupBanners, s.GroupMembers)
		fmt.Printf("  events=%d (photos=%d) chats=%d messages=%d\n",
			s.Events, s.EventPhotos, s.Chats, s.Messages)
		fmt.Printf("  matches=%d game_states=%d reactions=%d results=%d\n",
			s.Matches, s.GameStates, s.Reactions, s.Results)
		if len(s.Errors) > 0 {
			fmt.Printf("  seed errors: %d (first 5)\n", len(s.Errors))
			for i, e := range s.Errors {
				if i >= 5 {
					break
				}
				fmt.Printf("    - %s\n", e)
			}
		}
	}

	if len(r.Load) > 0 {
		fmt.Println()
		fmt.Println("── load ──────────────────────────────────────────────────────")
		rows := make([][]string, 0, len(r.Load))
		for _, s := range r.Load {
			rows = append(rows, []string{
				s.Op,
				fmt.Sprintf("%d", s.Count),
				fmt.Sprintf("%d", s.Errors),
				fmt.Sprintf("%.1f", s.RPS),
				s.P50.Round(time.Millisecond).String(),
				s.P90.Round(time.Millisecond).String(),
				s.P99.Round(time.Millisecond).String(),
				s.Max.Round(time.Millisecond).String(),
			})
		}
		format.RenderTable([]string{"op", "count", "errors", "req/s", "p50", "p90", "p99", "max"}, rows)
	}

	if r.Realtime != nil {
		rt := r.Realtime
		fmt.Println()
		fmt.Println("── realtime ──────────────────────────────────────────────────")
		fmt.Printf("  clients=%d joined=%d declined=%d events=%d\n",
			rt.Clients, rt.Stats.Joined, rt.Stats.Declined, rt.Stats.Events)
		fmt.Printf("  delivery latency: p50=%s p95=%s p99=%s max=%s (samples=%d)\n",
			rt.Delivery.P50.Round(time.Millisecond), rt.Delivery.P95.Round(time.Millisecond),
			rt.Delivery.P99.Round(time.Millisecond), rt.Delivery.Max.Round(time.Millisecond), rt.Delivery.Count)
		if len(rt.Errors) > 0 {
			fmt.Printf("  realtime errors: %d (first 3)\n", len(rt.Errors))
			for i, e := range rt.Errors {
				if i >= 3 {
					break
				}
				fmt.Printf("    - %s\n", e)
			}
		}
	}

	fmt.Println()
	fmt.Printf("  load ops: %d errors: %d error-rate: %.3f%% (max %.3f%%)\n",
		r.TotalOps, r.TotalErrors, r.ErrorRate*100, r.MaxErrorRate*100)
	if r.Passed {
		fmt.Println("  ✅ PASS")
	} else {
		fmt.Println("  ❌ FAIL")
	}
	fmt.Println("═══════════════════════════════════════════════════════════════")
}
