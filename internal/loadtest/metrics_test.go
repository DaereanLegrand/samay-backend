package loadtest

import (
	"errors"
	"testing"
	"time"
)

func TestPercentileNearestRank(t *testing.T) {
	sorted := make([]time.Duration, 100)
	for i := range sorted {
		sorted[i] = time.Duration(i+1) * time.Millisecond
	}
	cases := []struct {
		p    float64
		want time.Duration
	}{
		{0, 1 * time.Millisecond},
		{50, 50 * time.Millisecond},
		{90, 90 * time.Millisecond},
		{95, 95 * time.Millisecond},
		{99, 99 * time.Millisecond},
		{100, 100 * time.Millisecond},
	}
	for _, c := range cases {
		if got := percentile(sorted, c.p); got != c.want {
			t.Errorf("percentile(p=%v) = %s, want %s", c.p, got, c.want)
		}
	}
	if got := percentile(nil, 99); got != 0 {
		t.Errorf("percentile(nil) = %s, want 0", got)
	}
}

func TestRecorderAggregates(t *testing.T) {
	r := NewRecorder()
	r.Record("read", 10*time.Millisecond, nil)
	r.Record("read", 20*time.Millisecond, nil)
	r.Record("read", 30*time.Millisecond, nil)
	r.Record("write", 5*time.Millisecond, nil)
	r.Record("write", 2*time.Millisecond, errors.New("boom"))

	snap := r.Snapshot()
	if len(snap) != 2 {
		t.Fatalf("snapshot len = %d, want 2", len(snap))
	}
	// Snapshot is sorted by op for stable output.
	if snap[0].Op != "read" || snap[1].Op != "write" {
		t.Fatalf("snapshot order = %q,%q", snap[0].Op, snap[1].Op)
	}
	read := snap[0]
	if read.Count != 3 || read.Errors != 0 {
		t.Errorf("read count/errors = %d/%d", read.Count, read.Errors)
	}
	if read.P50 != 20*time.Millisecond {
		t.Errorf("read P50 = %s, want 20ms", read.P50)
	}
	if read.Max != 30*time.Millisecond {
		t.Errorf("read Max = %s, want 30ms", read.Max)
	}
	write := snap[1]
	if write.Count != 2 || write.Errors != 1 {
		t.Errorf("write count/errors = %d/%d, want 2/1", write.Count, write.Errors)
	}
}

func TestRecorderWindow(t *testing.T) {
	r := NewRecorder()
	r.Record("op", time.Millisecond, nil)
	r.Record("op", time.Millisecond, nil)
	if got := r.Total(); got != 2 {
		t.Errorf("Total = %d, want 2", got)
	}
	if got := r.Errors(); got != 0 {
		t.Errorf("Errors = %d, want 0", got)
	}
}

func TestRealtimeCounter(t *testing.T) {
	var c RealtimeCounter
	c.Joined()
	c.Joined()
	c.Declined()
	c.Event()
	c.Event()
	c.Event()
	got := c.Snapshot()
	if got.Joined != 2 || got.Declined != 1 || got.Events != 3 {
		t.Errorf("counter = %+v", got)
	}
}

func TestLatencyHistogramDelivery(t *testing.T) {
	var h LatencyHistogram
	for _, d := range []time.Duration{5 * time.Millisecond, 15 * time.Millisecond, 25 * time.Millisecond} {
		h.Observe(d)
	}
	stats := h.Stats()
	if stats.Count != 3 {
		t.Fatalf("count = %d", stats.Count)
	}
	if stats.P50 != 15*time.Millisecond {
		t.Errorf("p50 = %s, want 15ms", stats.P50)
	}
	if stats.P95 != 25*time.Millisecond {
		t.Errorf("p95 = %s, want 25ms", stats.P95)
	}
}
