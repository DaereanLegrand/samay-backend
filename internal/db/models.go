package db

import (
	"encoding/json"
	"time"
)

type User struct {
	ID                    string     `json:"id"`
	Username              *string    `json:"username"`
	AvatarURL             *string    `json:"avatar_url"`
	DateOfBirth           *string    `json:"date_of_birth"`
	Bio                   *string    `json:"bio"`
	BannedAt              *time.Time `json:"banned_at"`
	BanReason             *string    `json:"ban_reason"`
	DeletedAt             *time.Time `json:"deleted_at"`
	PersonalShards        int        `json:"personal_shards"`
	Preshards             int        `json:"preshards"`
	SubscriptionTier      string     `json:"subscription_tier"`
	SubscriptionExpiresAt *time.Time `json:"subscription_expires_at"`
	NotificationPrefs     json.RawMessage `json:"notification_preferences"`
	CreatedAt             time.Time  `json:"created_at"`
	UpdatedAt             time.Time  `json:"updated_at"`
}

type Cosmetic struct {
	ID              string    `json:"id"`
	Name            string    `json:"name"`
	Type            string    `json:"type"`
	AssetURL        string    `json:"asset_url"`
	ShardCost       int       `json:"shard_cost"`
	TierRequirement string    `json:"tier_requirement"`
	CreatedAt       time.Time `json:"created_at"`
}

type UserCosmetic struct {
	ID          string    `json:"id"`
	UserID      string    `json:"user_id"`
	CosmeticID  string    `json:"cosmetic_id"`
	Equipped    bool      `json:"equipped"`
	PurchasedAt time.Time `json:"purchased_at"`
}

type GroupCosmetic struct {
	ID          string    `json:"id"`
	GroupID     string    `json:"group_id"`
	CosmeticID  string    `json:"cosmetic_id"`
	Equipped    bool      `json:"equipped"`
	PurchasedAt time.Time `json:"purchased_at"`
}

type Friendship struct {
	ID          string    `json:"id"`
	RequesterID string    `json:"requester_id"`
	AddresseeID string    `json:"addressee_id"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
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

type GroupRankSnapshot struct {
	ID           string    `json:"id"`
	GroupID      string    `json:"group_id"`
	SizeTier     string    `json:"size_tier"`
	RankBracket  string    `json:"rank_bracket"`
	RankPosition int       `json:"rank_position"`
	Score        int       `json:"score"`
	MemberCount  int       `json:"member_count"`
	CalculatedAt time.Time `json:"calculated_at"`
}

type Event struct {
	ID                      string     `json:"id"`
	Name                    string     `json:"name"`
	Description             *string    `json:"description"`
	CoverURL                *string    `json:"cover_url"`
	Type                    string     `json:"type"`
	CreatedByUserID         string     `json:"created_by_user_id"`
	GroupID                 *string    `json:"group_id"`
	LocationName            *string    `json:"location_name"`
	LocationLat             *float64   `json:"location_lat"`
	LocationLng             *float64   `json:"location_lng"`
	StartsAt                time.Time  `json:"starts_at"`
	EndsAt                  time.Time  `json:"ends_at"`
	JoinMode                *string    `json:"join_mode"`
	PreshardsPool           int        `json:"preshards_pool"`
	PreshardsDistributed    bool       `json:"preshards_distributed"`
	PreshardsCapPerUser     *int       `json:"preshards_cap_per_user"`
	PreshardsRemainderAction *string   `json:"preshards_remainder_action"`
	DynamicQREnabled        bool       `json:"dynamic_qr_enabled"`
	InviteToken             string     `json:"invite_token"`
	Status                  string     `json:"status"`
	Featured                bool       `json:"featured"`
	FeaturedUntil           *time.Time `json:"featured_until"`
	CreatedAt               time.Time  `json:"created_at"`
	UpdatedAt               time.Time  `json:"updated_at"`
}

type EventPromotor struct {
	ID                  string    `json:"id"`
	EventID             string    `json:"event_id"`
	UserID              string    `json:"user_id"`
	Role                string    `json:"role"`
	PreshardsContributed int      `json:"preshards_contributed"`
	AddedAt             time.Time `json:"added_at"`
}

type EventInvite struct {
	ID              string     `json:"id"`
	EventID         string     `json:"event_id"`
	UserID          string     `json:"user_id"`
	InvitedByUserID string     `json:"invited_by_user_id"`
	Status          string     `json:"status"`
	InvitedAt       time.Time  `json:"invited_at"`
	RespondedAt     *time.Time `json:"responded_at"`
}

type EventQrToken struct {
	ID                  string     `json:"id"`
	EventID             string     `json:"event_id"`
	UserID              string     `json:"user_id"`
	Token               string     `json:"token"`
	ExpiresAt           time.Time  `json:"expires_at"`
	ScannedAt           *time.Time `json:"scanned_at"`
	AttendanceConfirmed bool       `json:"attendance_confirmed"`
	CreatedAt           time.Time  `json:"created_at"`
}

type EventAttendance struct {
	ID             string    `json:"id"`
	EventID        string    `json:"event_id"`
	UserID         string    `json:"user_id"`
	ConfirmedAt    time.Time `json:"confirmed_at"`
	ShardsReceived int       `json:"shards_received"`
}

type EventPhoto struct {
	ID              string    `json:"id"`
	EventID         string    `json:"event_id"`
	UploadedByUserID string   `json:"uploaded_by_user_id"`
	StoragePath     string    `json:"storage_path"`
	LikesCount      int       `json:"likes_count"`
	Reported        bool      `json:"reported"`
	CreatedAt       time.Time `json:"created_at"`
}

type EventPhotoLike struct {
	ID        string    `json:"id"`
	PhotoID   string    `json:"photo_id"`
	UserID    string    `json:"user_id"`
	CreatedAt time.Time `json:"created_at"`
}

type Chat struct {
	ID          string    `json:"id"`
	Type        string    `json:"type"`
	ReferenceID *string   `json:"reference_id"`
	CreatedAt   time.Time `json:"created_at"`
}

type Message struct {
	ID        string     `json:"id"`
	ChatID    string     `json:"chat_id"`
	SenderID  string     `json:"sender_id"`
	Content   string     `json:"content"`
	MediaURL  *string    `json:"media_url"`
	Reported  bool       `json:"reported"`
	CreatedAt time.Time  `json:"created_at"`
}

type ChatParticipant struct {
	ID        string    `json:"id"`
	ChatID    string    `json:"chat_id"`
	UserID    string    `json:"user_id"`
	CreatedAt time.Time `json:"created_at"`
}

type ShardLedgerEntry struct {
	ID          string    `json:"id"`
	UserID      *string   `json:"user_id"`
	Delta       int       `json:"delta"`
	Reason      string    `json:"reason"`
	ReferenceID *string   `json:"reference_id"`
	CreatedAt   time.Time `json:"created_at"`
}

type PreshardLedgerEntry struct {
	ID          string    `json:"id"`
	UserID      *string   `json:"user_id"`
	Delta       int       `json:"delta"`
	Reason      string    `json:"reason"`
	ReferenceID *string   `json:"reference_id"`
	CreatedAt   time.Time `json:"created_at"`
}

type MinigameSession struct {
	ID           string    `json:"id"`
	GroupID      string    `json:"group_id"`
	GameType     string    `json:"game_type"`
	Status       string    `json:"status"`
	ShardWager   int       `json:"shard_wager"`
	Participants []string  `json:"participants"`
	WinnerID     *string   `json:"winner_id"`
	CreatedAt    time.Time `json:"created_at"`
}

type Notification struct {
	ID        string           `json:"id"`
	UserID    string           `json:"user_id"`
	Type      string           `json:"type"`
	Title     string           `json:"title"`
	Body      string           `json:"body"`
	Data      *json.RawMessage `json:"data"`
	Read      bool             `json:"read"`
	CreatedAt time.Time        `json:"created_at"`
}

type FeatureRequest struct {
	ID                 string     `json:"id"`
	EventID            string     `json:"event_id"`
	RequestedByUserID  string     `json:"requested_by_user_id"`
	ContactInfo        string     `json:"contact_info"`
	DesiredDurationDays int       `json:"desired_duration_days"`
	Notes              *string    `json:"notes"`
	Status             string     `json:"status"`
	FeaturedUntil      *time.Time `json:"featured_until"`
	CreatedAt          time.Time  `json:"created_at"`
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

type AdminUser struct {
	ID          string    `json:"id"`
	Email       string    `json:"email"`
	DisplayName string    `json:"display_name"`
	Role        string    `json:"role"`
	CreatedAt   time.Time `json:"created_at"`
}

type AdminAuditLog struct {
	ID          string           `json:"id"`
	AdminUserID string           `json:"admin_user_id"`
	Action      string           `json:"action"`
	TargetType  string           `json:"target_type"`
	TargetID    string           `json:"target_id"`
	Details     *json.RawMessage `json:"details"`
	CreatedAt   time.Time        `json:"created_at"`
}

type SubscriptionOverride struct {
	ID          string     `json:"id"`
	UserID      string     `json:"user_id"`
	AdminUserID string     `json:"admin_user_id"`
	Tier        string     `json:"tier"`
	ExpiresAt   time.Time  `json:"expires_at"`
	Reason      *string    `json:"reason"`
	Revoked     bool       `json:"revoked"`
	CreatedAt   time.Time  `json:"created_at"`
}

type AppConfigRow struct {
	Key          string    `json:"key"`
	Value        string    `json:"value"`
	Description  *string   `json:"description"`
	DefaultValue *string   `json:"default_value"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type ProcessedWebhook struct {
	ID          string    `json:"id"`
	EventID     string    `json:"event_id"`
	EventType   string    `json:"event_type"`
	ProcessedAt time.Time `json:"processed_at"`
}

type SignupTracker struct {
	Email          string    `json:"email"`
	ProfileCreated bool      `json:"profile_created"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}
