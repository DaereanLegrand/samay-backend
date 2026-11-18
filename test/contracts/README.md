# Contract fixtures

Freezes the wire shapes shared by the Go server and the Flutter client.
Fixtures live here as `*.contract.json`; `backend/internal/contracts` (Go)
validates the same files. The fixture list is directory-derived, so deleting a
fixture removes only its own check — per-file shape validation stays strict.

No CI (removed by owner decision): run `go test ./internal/contracts`.

## Fixture format

```json
{
  "name": "user_profile",
  "source": "public.users projection -> lib/core/models/user_profile.dart",
  "fields": { "id": "string", "avatar_url": "string|null" },
  "enums": { "subscription_tier": ["free", "pro", "vip"] },
  "samples": [ { "...": "exactly the fields above" } ]
}
```

- `fields` is the frozen key set. Samples must contain **exactly** those keys
  (a rename or removal fails the test).
- Type expressions: `string`, `integer`, `number`, `boolean`, `object`,
  `array`, `date` (RFC 3339 string), and `|null`.
- `enums` constrain non-null values.
- `codes` (error fixture) is a list of stable error codes.

## Fixture inventory (slim-prod)

Slim-prod keeps games, auth, profile, settings, notifications/push, friends,
groups and prompt packs. The fixtures for removed domains (events, E2EE chat,
photos, user ranking) were deleted with those features:

| Fixture | Surface |
|---|---|
| `admin_user.contract.json` | `internal/db/models.go db.User` → `samay-admin` JSON (frozen tags) |
| `group.contract.json` | `groups` + caller membership → client group model |
| `group_theme.contract.json` | `get_group_theme(uuid)` → theme model |
| `user_profile.contract.json` | `public.users` projection → profile model |
| `subscription_state.contract.json` | `public.users` subscription columns → paywall/admin |
| `error_codes.contract.json` | stable SQL ERRCODEs + PostgREST/Go response codes |

Deleted with their features: `event.contract.json`, `event_search_row.contract.json`,
`admin_event.contract.json`, `direct_chat_ok.contract.json`,
`direct_chat_blocked.contract.json`, `user_ranking_row.contract.json`.

## Rules

- A field may only change with the lane that owns it; update the fixture in the
  same commit.
- Additive fields are allowed only when the owner lane documents them in
  `12-evidence.md`.
- E4 removes `entitlement_tier`; delete it from the fixture there, not before.
