package push

import (
	"encoding/json"
	"testing"
)

func decodePayload(t *testing.T, token string, msg Message) map[string]any {
	t.Helper()
	raw, err := payload(token, msg)
	if err != nil {
		t.Fatalf("payload: %v", err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("decode payload: %v", err)
	}
	return out
}

func messageMap(t *testing.T, token string, msg Message) map[string]any {
	t.Helper()
	out := decodePayload(t, token, msg)
	m, ok := out["message"].(map[string]any)
	if !ok {
		t.Fatalf("payload missing message object: %v", out)
	}
	return m
}

func dataMap(t *testing.T, token string, msg Message) map[string]any {
	t.Helper()
	d, ok := messageMap(t, token, msg)["data"].(map[string]any)
	if !ok {
		t.Fatalf("payload missing data map")
	}
	return d
}

func TestPayloadHasNoNotificationBlockOrCopy(t *testing.T) {
	msg := Message{NotificationID: "9f1c0e5e-1a2b-4c3d-8e9f-0123456789ab", Type: "minigame_turn"}
	m := messageMap(t, "device-token", msg)

	if _, ok := m["notification"]; ok {
		t.Fatalf("payload must not contain a notification block: %v", m)
	}
	data := dataMap(t, "device-token", msg)
	for _, key := range []string{"title", "body"} {
		if _, ok := m[key]; ok {
			t.Fatalf("payload must not contain top-level %q: %v", key, m)
		}
		if _, ok := data[key]; ok {
			t.Fatalf("payload data must not contain %q", key)
		}
	}
}

func TestPayloadDataOnlyAllowListedKeys(t *testing.T) {
	msg := Message{NotificationID: "abc-123", Type: "minigame_invite"}
	data := dataMap(t, "device-token", msg)

	if len(data) != len(allowedDataKeys) {
		t.Fatalf("data has %d keys, want %d: %v", len(data), len(allowedDataKeys), data)
	}
	for key := range data {
		if _, ok := allowedDataKeys[key]; !ok {
			t.Fatalf("data key %q is not allow-listed: %v", key, data)
		}
	}
	if data[dataKeyNotificationID] != msg.NotificationID {
		t.Fatalf("notification_id = %v, want %q", data[dataKeyNotificationID], msg.NotificationID)
	}
	if data[dataKeyType] != msg.Type {
		t.Fatalf("type = %v, want %q", data[dataKeyType], msg.Type)
	}
	if data[dataKeyTitleKey] != GenericTitleKey {
		t.Fatalf("titleKey = %v, want %q", data[dataKeyTitleKey], GenericTitleKey)
	}
	if data[dataKeyBodyKey] != GenericBodyKey {
		t.Fatalf("bodyKey = %v, want %q", data[dataKeyBodyKey], GenericBodyKey)
	}
}

func TestPayloadCarriesNoSensitiveKeys(t *testing.T) {
	forbidden := []string{
		"title", "body", "sender", "senderName", "sender_name",
		"location", "wager", "amount", "answer", "prompt",
		"text", "preview", "deepLink", "sessionId", "gameType",
	}
	msg := Message{NotificationID: "abc-123", Type: "minigame_turn"}
	data := dataMap(t, "device-token", msg)
	for _, key := range forbidden {
		if _, ok := data[key]; ok {
			t.Fatalf("data must not contain sensitive key %q: %v", key, data)
		}
	}
	for key := range data {
		if _, ok := allowedDataKeys[key]; !ok {
			t.Fatalf("unexpected data key %q: %v", key, data)
		}
	}
}

func TestPayloadAPNsIsSilentBackground(t *testing.T) {
	msg := Message{NotificationID: "abc-123", Type: "minigame_turn"}
	apns, ok := messageMap(t, "device-token", msg)["apns"].(map[string]any)
	if !ok {
		t.Fatalf("payload missing apns object")
	}
	headers, ok := apns["headers"].(map[string]any)
	if !ok {
		t.Fatalf("apns missing headers")
	}
	if headers["apns-priority"] != "5" {
		t.Fatalf("apns-priority = %v, want 5", headers["apns-priority"])
	}
	if headers["apns-push-type"] != "background" {
		t.Fatalf("apns-push-type = %v, want background", headers["apns-push-type"])
	}
	payload, ok := apns["payload"].(map[string]any)
	if !ok {
		t.Fatalf("apns missing payload")
	}
	aps, ok := payload["aps"].(map[string]any)
	if !ok {
		t.Fatalf("apns payload missing aps")
	}
	if aps["content-available"] != float64(1) {
		t.Fatalf("content-available = %v, want 1", aps["content-available"])
	}
	if aps["mutable-content"] != float64(1) {
		t.Fatalf("mutable-content = %v, want 1", aps["mutable-content"])
	}
	for _, key := range []string{"alert", "sound", "title", "body"} {
		if _, ok := aps[key]; ok {
			t.Fatalf("aps must not contain %q: %v", key, aps)
		}
	}
}

func TestPayloadAndroidHighPriority(t *testing.T) {
	msg := Message{NotificationID: "abc-123", Type: "minigame_turn"}
	android, ok := messageMap(t, "device-token", msg)["android"].(map[string]any)
	if !ok {
		t.Fatalf("payload missing android object")
	}
	if android["priority"] != "high" {
		t.Fatalf("android priority = %v, want high", android["priority"])
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
