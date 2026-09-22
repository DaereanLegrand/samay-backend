package validate

import (
	"testing"
	"time"
)

func TestOneOf(t *testing.T) {
	if err := OneOf("pro", "free", "pro", "vip"); err != nil {
		t.Fatalf("expected pro to be allowed, got %v", err)
	}
	err := OneOf("gold", "free", "pro", "vip")
	if err == nil {
		t.Fatal("expected gold to be rejected")
	}
	if want := `invalid value "gold": must be one of free, pro, vip`; err.Error() != want {
		t.Fatalf("error = %q, want %q", err.Error(), want)
	}
}

func TestParseDate(t *testing.T) {
	got, err := ParseDate("2026-09-21")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := time.Date(2026, 9, 21, 0, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("date = %v, want %v", got, want)
	}

	for _, in := range []string{"21-09-2026", "2026/09/21", "", "not-a-date"} {
		if _, err := ParseDate(in); err == nil {
			t.Fatalf("expected %q to be rejected", in)
		}
	}
}

func TestParsePositiveInt(t *testing.T) {
	n, err := ParsePositiveInt("42")
	if err != nil || n != 42 {
		t.Fatalf("ParsePositiveInt(42) = %d, %v; want 42, nil", n, err)
	}
	for _, in := range []string{"0", "-1", "abc", ""} {
		if _, err := ParsePositiveInt(in); err == nil {
			t.Fatalf("expected %q to be rejected", in)
		}
	}
}

func TestParseUUID(t *testing.T) {
	valid := []string{
		"32323232-3232-3232-3232-323232323232",
		"ABCDEF01-2345-6789-abcd-ef0123456789",
	}
	for _, s := range valid {
		if err := ParseUUID(s); err != nil {
			t.Fatalf("expected %q valid, got %v", s, err)
		}
	}

	invalid := []string{
		"",
		"32323232-3232-3232-3232-32323232323",   // too short
		"32323232-3232-3232-3232-3232323232322", // too long
		"323232323232-3232-3232-323232323232",   // misplaced dashes
		"32323232-3232-3232-3232-32323232323g",  // non-hex
	}
	for _, s := range invalid {
		if err := ParseUUID(s); err == nil {
			t.Fatalf("expected %q invalid", s)
		}
	}
}
