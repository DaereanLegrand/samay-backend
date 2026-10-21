package auth

import (
	"math"
	"sync"
	"time"
)

// RateLimiter is a per-key token bucket. It is safe for concurrent use.
type RateLimiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	rate    float64
	burst   float64
	now     func() time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

const (
	// maxBuckets bounds memory under a spoofed-IP flood. Once reached, full
	// buckets idle longer than bucketTTL are evicted; if none qualify the map
	// simply stops growing and known keys keep their state.
	maxBuckets = 8192
	bucketTTL  = 10 * time.Minute
)

// NewRateLimiter returns a limiter refilling at rate tokens/second with the
// given burst capacity.
func NewRateLimiter(rate float64, burst int) *RateLimiter {
	if rate <= 0 {
		rate = 1
	}
	if burst < 1 {
		burst = 1
	}
	return &RateLimiter{
		buckets: make(map[string]*bucket),
		rate:    rate,
		burst:   float64(burst),
		now:     time.Now,
	}
}

// Allow consumes one token for key. When the bucket is empty it returns false
// and the minimum wait before the next request.
func (l *RateLimiter) Allow(key string) (bool, time.Duration) {
	now := l.now()

	l.mu.Lock()
	defer l.mu.Unlock()

	b, ok := l.buckets[key]
	if !ok {
		if len(l.buckets) >= maxBuckets {
			l.pruneLocked(now)
		}
		b = &bucket{tokens: l.burst, last: now}
		l.buckets[key] = b
	} else {
		elapsed := now.Sub(b.last).Seconds()
		if elapsed > 0 {
			b.tokens = math.Min(l.burst, b.tokens+elapsed*l.rate)
			b.last = now
		}
	}

	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	missing := 1 - b.tokens
	wait := time.Duration(math.Ceil(missing/l.rate*1000)) * time.Millisecond
	if wait < time.Second {
		wait = time.Second
	}
	return false, wait
}

func (l *RateLimiter) pruneLocked(now time.Time) {
	for key, b := range l.buckets {
		if b.tokens >= l.burst && now.Sub(b.last) > bucketTTL {
			delete(l.buckets, key)
		}
	}
}
