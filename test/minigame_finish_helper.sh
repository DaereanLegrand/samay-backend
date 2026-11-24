#!/usr/bin/env bash
# =============================================================================
# minigame_finish_helper.sh — test-only settlement helper (sourced, not run)
#
# 229_wave0 revoked EXECUTE on public.finish_minigame_game(uuid) from
# `authenticated`: settlement is server-role-only now (the play engine calls it
# internally as its SECURITY DEFINER owner). Legacy opt tests that asserted the
# client could call the RPC need to mint a service-role token carrying the
# participant's `sub` — the function's own access gate still applies, so a
# bystander is rejected with `not_allowed` exactly as before.
# =============================================================================

_finish_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${JWT_SECRET:-}" ]; then
  JWT_SECRET="$(sed -n 's/^JWT_SECRET=//p' "$_finish_root/.env/testing-local.env" \
    | head -1 | tr -d '"')"
fi

mint_service_jwt() { # mint_service_jwt <user-id>
  JWT_SECRET="$JWT_SECRET" SUB="$1" python3 - <<'PY'
import base64, hashlib, hmac, json, os, time

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

now = int(time.time())
header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
payload = b64(json.dumps({
    "role": "service_role",
    "aud": "authenticated",
    "sub": os.environ["SUB"],
    "iss": "supabase",
    "iat": now,
    "exp": now + 3600,
}, separators=(",", ":")).encode())
signed = f"{header}.{payload}".encode()
sig = b64(hmac.new(os.environ["JWT_SECRET"].encode(), signed, hashlib.sha256).digest())
print(f"{header}.{payload}.{sig}")
PY
}

finish_game() { # finish_game <user-id> <session-id>
  local token
  token="$(mint_service_jwt "$1")"
  curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/finish_minigame_game" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "{\"p_session_id\":\"$2\"}"
}
