package db

import (
	"encoding/json"
	"time"
)

type User struct {
	ID                    string          `json:"id"`
	Username              *string         `json:"username"`
	AvatarURL             *string         `json:"avatar_url"`
	DateOfBirth           *string         `json:"date_of_birth"`
	Bio                   *string         `json:"bio"`
	BannedAt              *time.Time      `json:"banned_at"`
	BanReason             *string         `json:"ban_reason"`
	DeletedAt             *time.Time      `json:"deleted_at"`
	PersonalShards        int             `json:"personal_shards"`
	Preshards             int             `json:"preshards"`
	SubscriptionTier      string          `json:"subscription_tier"`
	SubscriptionExpiresAt *time.Time      `json:"subscription_expires_at"`
	NotificationPrefs     json.RawMessage `json:"notification_preferences"`
	CreatedAt             time.Time       `json:"created_at"`
	UpdatedAt             time.Time       `json:"updated_at"`
}

type Group struct {
	ID              string     `json:"id"`
	Name            string     `json:"name"`
	Description     *string    `json:"description"`
	CoverURL        *string    `json:"cover_url"`
	CreatedByUserID string     `json:"created_by_user_id"`
	GroupShards     int        `json:"group_shards"`
	SizeTier        *string    `json:"size_tier"`
	RankBracket     *string    `json:"rank_bracket"`
	FrozenAt        *time.Time `json:"frozen_at"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

type GroupMember struct {
	ID       string    `json:"id"`
	GroupID  string    `json:"group_id"`
	UserID   string    `json:"user_id"`
	Role     string    `json:"role"`
	Status   string    `json:"status"`
	JoinedAt time.Time `json:"joined_at"`
}

type GroupShardContribution struct {
	ID                string    `json:"id"`
	GroupID           string    `json:"group_id"`
	UserID            string    `json:"user_id"`
	ShardsContributed int       `json:"shards_contributed"`
	ContributedAt     time.Time `json:"contributed_at"`
	ExpiresAt         time.Time `json:"expires_at"`
}

type Event struct {
	ID                       string     `json:"id"`
	Name                     string     `json:"name"`
	Description              *string    `json:"description"`
	CoverURL                 *string    `json:"cover_url"`
	Type                     string     `json:"type"`
	CreatedByUserID          string     `json:"created_by_user_id"`
	GroupID                  *string    `json:"group_id"`
	LocationName             *string    `json:"location_name"`
	LocationLat              *float64   `json:"location_lat"`
	LocationLng              *float64   `json:"location_lng"`
	StartsAt                 time.Time  `json:"starts_at"`
	EndsAt                   time.Time  `json:"ends_at"`
	JoinMode                 *string    `json:"join_mode"`
	PreshardsPool            int        `json:"preshards_pool"`
	PreshardsDistributed     bool       `json:"preshards_distributed"`
	PreshardsCapPerUser      *int       `json:"preshards_cap_per_user"`
	PreshardsRemainderAction *string    `json:"preshards_remainder_action"`
	DynamicQREnabled         bool       `json:"dynamic_qr_enabled"`
	InviteToken              string     `json:"invite_token"`
	Status                   string     `json:"status"`
	Featured                 bool       `json:"featured"`
	FeaturedUntil            *time.Time `json:"featured_until"`
	CreatedAt                time.Time  `json:"created_at"`
	UpdatedAt                time.Time  `json:"updated_at"`
}

type EventHost struct {
	ID                   string    `json:"id"`
	EventID              string    `json:"event_id"`
	UserID               string    `json:"user_id"`
	Role                 string    `json:"role"`
	PreshardsContributed int       `json:"preshards_contributed"`
	AddedAt              time.Time `json:"added_at"`
}

type ShardLedgerEntry struct {
	ID          string    `json:"id"`
	UserID      *string   `json:"user_id"`
	Delta       int       `json:"delta"`
	Reason      string    `json:"reason"`
	ReferenceID *string   `json:"reference_id"`
	CreatedAt   time.Time `json:"created_at"`
}

type FeatureRequest struct {
	ID                  string     `json:"id"`
	EventID             string     `json:"event_id"`
	RequestedByUserID   string     `json:"requested_by_user_id"`
	ContactInfo         string     `json:"contact_info"`
	DesiredDurationDays int        `json:"desired_duration_days"`
	Notes               *string    `json:"notes"`
	Status              string     `json:"status"`
	FeaturedUntil       *time.Time `json:"featured_until"`
	CreatedAt           time.Time  `json:"created_at"`
}

type Report struct {
	ID         string    `json:"id"`
	ReporterID string    `json:"reporter_id"`
	TargetType string    `json:"target_type"`
	TargetID   string    `json:"target_id"`
	Reason     string    `json:"reason"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
}

type AppConfigRow struct {
	Key          string    `json:"key"`
	Value        string    `json:"value"`
	Description  *string   `json:"description"`
	DefaultValue *string   `json:"default_value"`
	UpdatedAt    time.Time `json:"updated_at"`
}
