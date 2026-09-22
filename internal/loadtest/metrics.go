package loadtest

import (
	"sort"
	"sync"
	"time"
)

// OpStats is the aggregated result for one logical operation.
type OpStats struct {
	Op      string        `json:"op"`
	Count   int64         `json:"count"`
	Errors  int64         `json:"errors"`
	Mean    time.Duration `json:"mean"`
	P50     time.Duration `json:"p50"`
	P90     time.Duration `json:"p90"`
	P95     time.Duration `json:"p95"`
	P99     time.Duration `json:"p99"`
	Max     time.Duration `json:"max"`
	RPS     float64       `json:"rps"`
	Elapsed time.Duration `json:"elapsed"`
}

type opData struct {
	durations []time.Duration
	errors    int64
}

// Recorder aggregates per-operation latency samples and error counts. Safe for
// concurrent use by all workers.
type Recorder struct {
	mu    sync.Mutex
	ops   map[string]*opData
	total int64
	errs  int64
	start time.Time
}

func NewRecorder() *Recorder {
	return &Recorder{ops: make(map[string]*opData), start: time.Now()}
}

// Record adds one observation. d is the measured latency and err is non-nil
// when the operation failed.
func (r *Recorder) Record(op string, d time.Duration, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	od := r.ops[op]
	if od == nil {
		od = &opData{}
		r.ops[op] = od
	}
	od.durations = append(od.durations, d)
	if err != nil {
		od.errors++
		r.errs++
	}
	r.total++
}

// Total returns the number of recorded operations.
func (r *Recorder) Total() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.total
}

// Errors returns the number of failed operations.
func (r *Recorder) Errors() int64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.errs
}

// Snapshot returns stats sorted by operation name for stable output.
func (r *Recorder) Snapshot() []OpStats {
	r.mu.Lock()
	defer r.mu.Unlock()
	elapsed := time.Since(r.start)
	out := make([]OpStats, 0, len(r.ops))
	for op, od := range r.ops {
		stats := OpStats{Op: op, Count: int64(len(od.durations)), Errors: od.errors, Elapsed: elapsed}
		if stats.Count > 0 {
			sorted := append([]time.Duration(nil), od.durations...)
			sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
			var sum time.Duration
			for _, d := range sorted {
				sum += d
			}
			stats.Mean = sum / time.Duration(len(sorted))
			stats.P50 = percentile(sorted, 50)
			stats.P90 = percentile(sorted, 90)
			stats.P95 = percentile(sorted, 95)
			stats.P99 = percentile(sorted, 99)
			stats.Max = sorted[len(sorted)-1]
		}
		if elapsed > 0 {
			stats.RPS = float64(stats.Count) / elapsed.Seconds()
		}
		out = append(out, stats)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Op < out[j].Op })
	return out
}

// percentile returns the nearest-rank percentile of an ascending slice.
func percentile(sorted []time.Duration, p float64) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	if p <= 0 {
		return sorted[0]
	}
	rank := int(float64(p)/100.0*float64(len(sorted)) + 0.999999)
	if rank < 1 {
		rank = 1
	}
	if rank > len(sorted) {
		rank = len(sorted)
	}
	return sorted[rank-1]
}

// RealtimeStats summarizes realtime subscription activity.
type RealtimeStats struct {
	Joined   int64 `json:"joined"`
	Declined int64 `json:"declined"`
	Events   int64 `json:"events"`
}

// RealtimeCounter is a concurrency-safe counter for realtime outcomes.
type RealtimeCounter struct {
	mu       sync.Mutex
	joined   int64
	declined int64
	events   int64
}

func (c *RealtimeCounter) Joined() {
	c.mu.Lock()
	c.joined++
	c.mu.Unlock()
}

func (c *RealtimeCounter) Declined() {
	c.mu.Lock()
	c.declined++
	c.mu.Unlock()
}

func (c *RealtimeCounter) Event() {
	c.mu.Lock()
	c.events++
	c.mu.Unlock()
}

func (c *RealtimeCounter) Snapshot() RealtimeStats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return RealtimeStats{Joined: c.joined, Declined: c.declined, Events: c.events}
}

// LatencyStats summarizes a latency sample set.
type LatencyStats struct {
	Count int64         `json:"count"`
	P50   time.Duration `json:"p50"`
	P95   time.Duration `json:"p95"`
	P99   time.Duration `json:"p99"`
	Max   time.Duration `json:"max"`
}

// LatencyHistogram accumulates durations for percentile reporting.
type LatencyHistogram struct {
	mu  sync.Mutex
	buf []time.Duration
}

func (h *LatencyHistogram) Observe(d time.Duration) {
	h.mu.Lock()
	h.buf = append(h.buf, d)
	h.mu.Unlock()
}

func (h *LatencyHistogram) Stats() LatencyStats {
	h.mu.Lock()
	defer h.mu.Unlock()
	stats := LatencyStats{Count: int64(len(h.buf))}
	if len(h.buf) == 0 {
		return stats
	}
	sorted := append([]time.Duration(nil), h.buf...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	stats.P50 = percentile(sorted, 50)
	stats.P95 = percentile(sorted, 95)
	stats.P99 = percentile(sorted, 99)
	stats.Max = sorted[len(sorted)-1]
	return stats
}
