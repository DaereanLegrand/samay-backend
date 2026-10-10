package push

import (
	"encoding/json"
	"testing"
)

func TestDataWithTypeInjectsTypeAndStringifies(t *testing.T) {
	n := notificationRow{
		Type: "minigame_turn",
		Data: json.RawMessage(`{"sessionId":"abc","count":3,"nested":{"a":1}}`),
	}
	got := dataWithType(n)

	if got["type"] != "minigame_turn" {
		t.Fatalf("type = %q, want minigame_turn", got["type"])
	}
	if got["sessionId"] != "abc" {
		t.Fatalf("sessionId = %q, want abc", got["sessionId"])
	}
	if got["count"] != "3" {
		t.Fatalf("count = %q, want \"3\"", got["count"])
	}
	if got["nested"] != `{"a":1}` {
		t.Fatalf("nested = %q, want {\"a\":1}", got["nested"])
	}
}

func TestDataWithTypeHandlesEmptyData(t *testing.T) {
	got := dataWithType(notificationRow{Type: "minigame_invite"})
	if len(got) != 1 || got["type"] != "minigame_invite" {
		t.Fatalf("unexpected map: %v", got)
	}
}

func TestIsUnregistered(t *testing.T) {
	cases := map[string]bool{
		`{"error":{"status":"UNREGISTERED"}}`:                  true,
		`{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}`: true,
		`{"error":{"status":"NOT_FOUND"}}`:                     true,
		`{"error":{"status":"INVALID_ARGUMENT"}}`:              false,
		`registration-token-not-registered`:                    true,
		`{"error":{"status":"INTERNAL"}}`:                      false,
	}
	for body, want := range cases {
		if got := isUnregistered([]byte(body)); got != want {
			t.Errorf("isUnregistered(%q) = %v, want %v", body, got, want)
		}
	}
}
