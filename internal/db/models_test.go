package db

import (
	"encoding/json"
	"testing"
	"time"
)

func TestUserStruct(t *testing.T) {
	u := User{
		ID:               "test-uuid",
		Username:         strPtr("testuser"),
		PersonalShards:   256,
		SubscriptionTier: "free",
		CreatedAt:        time.Now(),
	}
	data, err := json.Marshal(u)
	if err != nil {
		t.Fatalf("marshal user: %v", err)
	}
	var decoded User
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal user: %v", err)
	}
	if decoded.ID != "test-uuid" {
		t.Errorf("expected test-uuid, got %s", decoded.ID)
	}
}

func TestEventStruct(t *testing.T) {
	e := Event{
		ID:     "event-uuid",
		Name:   "Test Event",
		Type:   "juerga",
		Status: "upcoming",
	}
	data, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	var decoded Event
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal event: %v", err)
	}
	if decoded.Name != "Test Event" {
		t.Errorf("expected Test Event, got %s", decoded.Name)
	}
}

func strPtr(s string) *string { return &s }
