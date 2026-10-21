package auth

import (
	"testing"
	"time"
)

func TestRateLimiter_BurstThenRefill(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	l := NewRateLimiter(1, 2)
	l.now = func() time.Time { return now }

	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("first request should pass")
	}
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("second request should pass")
	}
	ok, wait := l.Allow("k")
	if ok {
		t.Fatal("third request should be limited")
	}
	if wait < time.Second {
		t.Fatalf("wait = %s, want at least 1s", wait)
	}

	now = now.Add(2 * time.Second)
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("bucket should refill after waiting")
	}
}

func TestRateLimiter_KeysAreIndependent(t *testing.T) {
	l := NewRateLimiter(0.1, 1)
	if ok, _ := l.Allow("a"); !ok {
		t.Fatal("a should pass")
	}
	if ok, _ := l.Allow("a"); ok {
		t.Fatal("a should be limited")
	}
	if ok, _ := l.Allow("b"); !ok {
		t.Fatal("b should have its own bucket")
	}
}

func TestRateLimiter_InvalidConfigDefaults(t *testing.T) {
	l := NewRateLimiter(0, 0)
	if l.rate <= 0 || l.burst < 1 {
		t.Fatalf("invalid defaults: rate=%v burst=%v", l.rate, l.burst)
	}
	if ok, _ := l.Allow("k"); !ok {
		t.Fatal("first request should pass")
	}
}
