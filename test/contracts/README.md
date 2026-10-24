# Contract fixtures (E0)

Wave 2 freezes the wire shapes shared by the Go server and the Flutter client
before the E1–E4 lanes split. Fixtures live here as `*.contract.json`; both
`backend/internal/contracts` (Go) and `frontend/test/contracts_test.dart`
(Dart) validate the same files.

No CI: run `go test ./internal/contracts` and `flutter test test/contracts_test.dart`.

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

## D1–D16 inventory against `wave1b-base`

| ID | State at base | Contract owner | Notes |
|---|---|---|---|
| D1 | fixed (`229`) | `event.contract.json` (shards) | `purchase_cosmetic` exists; direct writes revoked |
| D2 | pending E4 | `direct_chat_*.contract.json` | 226 returns `{status:"blocked"}`; client still throws on missing `chatId` |
| D3 | pending E3 | `event_search_row` / notification | key-distribution rows still notify (no `recipient_id` filter) |
| D4 | pending E3 | — | no in-app reset route; `config.toml site_url` is `127.0.0.1:3000` |
| D5 | fixed 1B (`235`) | — | join RPCs + native link registration; universal links need the website deploy |
| D6 | pending E2/E4 | `user_profile` / `subscription_state` | paywall still reads auth metadata |
| D7 | pending E3 | — | photo window remains client-only |
| D8 | fixed 1B (`234`) | `event_search_row` (push) | `notifications.push_allowed` + server prefs; worker filters |
| D9 | pending E3 | `group.contract.json` | client still does 3 inserts; no `create_group` RPC |
| D10 | fixed 1B | — | `internal/ops/users.go` uses `time.Now()` |
| D11 | pending E1 | — | `dispatch_shard_distribution` only logs |
| D12 | fixed 1B (`234/01`) | — | `notify_group_invite` trigger |
| D13 | pending E4 | `user_profile` | `entitlementTier` still on the wire |
| D14 | pending E4 | — | collage ignores `collage_top_n_photos` |
| D15 | pending E2 | `subscription_state` | webhook still substring-matches entitlement ids |
| D16 | fixed E3 | `admin_event.contract.json` | `db.Event.capacity` added; admin JSON includes it |

## Rules

- A field may only change with the lane that owns it; update the fixture in the
  same commit.
- Additive fields are allowed only when the owner lane documents them in
  `12-evidence.md`.
- E4 removes `entitlement_tier`; delete it from the fixture there, not before.
