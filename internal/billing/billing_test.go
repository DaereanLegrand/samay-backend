package billing

import (
	"testing"
	"time"
)

func TestParseEntitlementMap(t *testing.T) {
	m, err := ParseEntitlementMap(`{"samay_testing_pro":"pro","samay_testing_vip":"vip"}`)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if m["samay_testing_vip"] != VIP {
		t.Fatalf("vip mapping = %q", m["samay_testing_vip"])
	}
	for _, raw := range []string{"", "{}", "[]", `{"x":"gold"}`, "not json"} {
		if _, err := ParseEntitlementMap(raw); err == nil {
			t.Fatalf("expected error for %q", raw)
		}
	}
}

func TestResolveTierExactMatch(t *testing.T) {
	m, _ := ParseEntitlementMap(`{"samay_pro":"pro","samay_vip":"vip"}`)

	tier, exp, err := m.ResolveTier(nil)
	if err != nil || tier != Free || exp != nil {
		t.Fatalf("no entitlements -> free, got %s %v %v", tier, exp, err)
	}

	expMs := time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC).UnixMilli()
	tier, exp, err = m.ResolveTier([]Entitlement{
		{ID: "samay_pro", ExpiresAt: expMs},
		{ID: "samay_vip", ExpiresAt: expMs},
	})
	if err != nil || tier != VIP {
		t.Fatalf("expected vip, got %s %v", tier, err)
	}
	if exp == nil || !exp.Equal(time.UnixMilli(expMs).UTC()) {
		t.Fatalf("expiry = %v", exp)
	}

	// No substring matching: a lookalike id fails closed.
	if _, _, err := m.ResolveTier([]Entitlement{{ID: "samay_pro_legacy"}}); err == nil {
		t.Fatal("unknown entitlement must fail closed")
	}
}

func TestNextAttemptSchedule(t *testing.T) {
	want := []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 2 * time.Hour, 12 * time.Hour}
	for i, d := range want {
		got, ok := NextAttempt(i + 1)
		if !ok || got != d {
			t.Fatalf("attempt %d = %v (ok=%v), want %v", i+1, got, ok, d)
		}
	}
	if _, ok := NextAttempt(6); ok {
		t.Fatal("attempt 6 must be out of schedule")
	}
	if _, ok := NextAttempt(0); ok {
		t.Fatal("attempt 0 must be out of schedule")
	}
}
