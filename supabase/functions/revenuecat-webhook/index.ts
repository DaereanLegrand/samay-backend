// Samay — RevenueCat webhook handler (RCBH).
//
// Endpoint: POST /functions/v1/revenuecat-webhook  (via Kong -> edge-runtime)
// Auth: the shared secret configured as the RevenueCat webhook's Authorization
//       header (env REVENUECAT_WEBHOOK_SECRET). Fail-closed when unset/blank.
//
// Contract (docs/specs/steps/phase-12-monetization-subscriptions/
// RCBH-revenuecat-webhook-handler.md):
//   * The tier is read STRICTLY from RevenueCat REST API v2
//     (GET /v2/projects/{id}/customers/{user}) — the event payload is not
//     trusted for the tier, and there is no payload fallback.
//   * Idempotent: every event id is recorded in public.processed_webhooks.
//   * Subscription events update users.subscription_tier +
//     subscription_expires_at through the SECURITY DEFINER RPC
//     public.apply_subscription_state (privileged write + audit).
//   * Transient failures are recorded in public.webhook_failures; the response
//     is still HTTP 200 so RevenueCat does not retry-storm (we retried it).
//
// The active-subscription clock the SOVR reconciler reads is
// users.subscription_expires_at, which this handler keeps current.

const encoder = new TextEncoder();

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WEBHOOK_SECRET = Deno.env.get("REVENUECAT_WEBHOOK_SECRET") ?? "";
// RevenueCat REST API v2 — the strict resync source of truth. Both are required
// for any tier change; when either is unset the handler fails closed (records a
// webhook_failure) instead of guessing from the event payload.
const RC_API_KEY = Deno.env.get("REVENUECAT_API_KEY") ?? "";
const RC_PROJECT_ID = Deno.env.get("REVENUECAT_PROJECT_ID") ?? "";
const RC_ENTITLEMENT_MAP = Deno.env.get("REVENUECAT_ENTITLEMENT_MAP") ?? "";
const RC_API_BASE = "https://api.revenuecat.com/v2";

// Events that (re)assert a paid tier.
const TIER_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "SUBSCRIPTION_EXTENDED",
  "NON_RENEWING_PURCHASE",
]);
// Events that end access now.
const RESET_EVENTS = new Set(["EXPIRATION"]);
// Immediate downgrade, bypassing the 24h grace (E2/Q25).
const IMMEDIATE_FREE = new Set(["REFUND", "CHARGEBACK"]);
// Billing problems keep paid actions to later of expiry or event + 7 days.
const GRACE_EVENTS = new Set(["BILLING_ISSUE", "SUBSCRIPTION_PAUSED"]);
// CANCELLATION keeps access until EXPIRATION; the rest carry no tier change.
const IGNORED_EVENTS = new Set([
  "CANCELLATION",
  "TEST",
  "SUBSCRIBER_ALIAS",
]);

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function svcHeaders(): HeadersInit {
  return {
    apikey: SERVICE_ROLE,
    Authorization: `Bearer ${SERVICE_ROLE}`,
    "Content-Type": "application/json",
  };
}

async function rest(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { ...svcHeaders(), ...(init.headers ?? {}) },
  });
}

// E2/D15: explicit per-environment entitlement -> tier map (exact match, no
// substring). `REVENUECAT_ENTITLEMENT_MAP` is JSON, e.g.
//   {"samay_testing_pro":"pro","samay_testing_vip":"vip"}
// An unmapped active entitlement fails closed and queues a webhook failure.
function entitlementMap(): Record<string, "pro" | "vip"> {
  if (!RC_ENTITLEMENT_MAP) {
    throw new Error("REVENUECAT_ENTITLEMENT_MAP is not configured");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(RC_ENTITLEMENT_MAP);
  } catch (err) {
    throw new Error(`REVENUECAT_ENTITLEMENT_MAP is not valid JSON: ${err}`);
  }
  if (
    !parsed || typeof parsed !== "object" || Array.isArray(parsed)
  ) {
    throw new Error("REVENUECAT_ENTITLEMENT_MAP must be a JSON object");
  }
  const map: Record<string, "pro" | "vip"> = {};
  for (const [key, value] of Object.entries(parsed as Record<string, unknown>)) {
    if (value !== "pro" && value !== "vip") {
      throw new Error(`REVENUECAT_ENTITLEMENT_MAP invalid tier for ${key}`);
    }
    map[key] = value;
  }
  return map;
}

// Read the customer from RevenueCat REST API v2 — the source of truth for the
// tier. `expires_at` is the latest mapped entitlement expiry (ms epoch). No
// active mapped entitlement => "free". Strict: any failure (non-2xx, network,
// missing config, unknown entitlement) throws so the event is queued as a
// webhook_failure — there is no event-payload fallback.
async function rcCustomerTier(
  userId: string,
): Promise<{ tier: "pro" | "vip" | "free"; expires: string | null }> {
  if (!RC_API_KEY || !RC_PROJECT_ID) {
    throw new Error(
      "RevenueCat v2 not configured (REVENUECAT_API_KEY / REVENUECAT_PROJECT_ID)",
    );
  }
  const map = entitlementMap();
  const url = `${RC_API_BASE}/projects/${encodeURIComponent(RC_PROJECT_ID)}` +
    `/customers/${encodeURIComponent(userId)}`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${RC_API_KEY}` },
  });
  if (!res.ok) {
    throw new Error(`rc v2 customer ${res.status}: ${await res.text()}`);
  }
  const data = (await res.json()) as {
    active_entitlements?: {
      items?: Array<{ entitlement_id?: string; expires_at?: number | null }>;
    };
  };
  const items = data.active_entitlements?.items ?? [];
  let tier: "pro" | "vip" | "free" = "free";
  let expiresMs = 0;
  for (const it of items) {
    const ent = String(it.entitlement_id ?? "");
    const mapped = map[ent];
    if (!mapped) {
      throw new Error(`unknown_entitlement:${ent || "(empty)"}`);
    }
    if (mapped === "vip") tier = "vip";
    else if (tier !== "vip") tier = "pro";
    const ms = Number(it.expires_at ?? 0);
    if (ms > expiresMs) expiresMs = ms;
  }
  return {
    tier,
    expires: expiresMs > 0 ? new Date(expiresMs).toISOString() : null,
  };
}

async function alreadyProcessed(eventId: string): Promise<boolean> {
  const res = await rest(
    `processed_webhooks?event_id=eq.${encodeURIComponent(eventId)}&select=id&limit=1`,
  );
  if (!res.ok) return false; // fail open to the unique constraint below
  const rows = await res.json();
  return Array.isArray(rows) && rows.length > 0;
}

async function markProcessed(id: string, type: string): Promise<void> {
  // Ignore-duplicates: a concurrent retry must not error.
  await rest("processed_webhooks?on_conflict=event_id", {
    method: "POST",
    headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
    body: JSON.stringify({ event_id: id, event_type: type }),
  });
}

async function recordFailure(
  id: string,
  type: string,
  payload: unknown,
  err: unknown,
): Promise<void> {
  try {
    await rest("webhook_failures", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({
        event_id: id,
        event_type: type,
        payload,
        last_error: String(err).slice(0, 2000),
        attempts: 1,
        next_attempt_at: new Date(Date.now() + 60_000).toISOString(),
      }),
    });
  } catch (_) {
    // best-effort only
  }
}

async function applyState(
  userId: string,
  tier: "pro" | "vip" | "free",
  expires: string | null,
  eventType: string,
): Promise<void> {
  const res = await rest("rpc/apply_subscription_state", {
    method: "POST",
    body: JSON.stringify({
      p_user: userId,
      p_tier: tier,
      p_expires: expires,
      p_event_type: eventType,
    }),
  });
  if (!res.ok) {
    throw new Error(`apply_subscription_state ${res.status}: ${await res.text()}`);
  }
}

async function applyGrace(
  userId: string,
  eventType: string,
  eventAt: string,
): Promise<void> {
  const res = await rest("rpc/apply_subscription_grace", {
    method: "POST",
    body: JSON.stringify({
      p_user: userId,
      p_event_type: eventType,
      p_event_at: eventAt,
    }),
  });
  if (!res.ok) {
    throw new Error(`apply_subscription_grace ${res.status}: ${await res.text()}`);
  }
}

// RevenueCat is the source of truth: resync the account and apply the result.
async function resyncUser(userId: string, eventType: string): Promise<void> {
  const { tier, expires } = await rcCustomerTier(userId);
  await applyState(userId, tier, expires, eventType);
}

function eventAtISO(evt: Record<string, unknown>): string {
  const ms = Number(evt.event_timestamp_ms ?? 0);
  return ms > 0 ? new Date(ms).toISOString() : new Date().toISOString();
}

function transferIds(evt: Record<string, unknown>, fallback: string): string[] {
  const ids = new Set<string>();
  for (const key of ["transferred_from", "transferred_to"]) {
    const value = evt[key];
    if (Array.isArray(value)) {
      for (const id of value) ids.add(String(id));
    }
  }
  ids.add(fallback);
  return [...ids].filter((id) => UUID_RE.test(id));
}

function authorized(req: Request): boolean {
  if (!WEBHOOK_SECRET) return false;
  const got = req.headers.get("Authorization") ?? "";
  const want = `Bearer ${WEBHOOK_SECRET}`;
  // Constant-time-ish compare (length gate + XOR accumulation).
  if (got.length !== want.length) return false;
  let diff = 0;
  for (let i = 0; i < got.length; i++) {
    diff |= got.charCodeAt(i) ^ want.charCodeAt(i);
  }
  return diff === 0;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }
  if (!authorized(req)) {
    return new Response("unauthorized", { status: 401 });
  }
  if (!SUPABASE_URL || !SERVICE_ROLE) {
    return new Response("server not configured", { status: 503 });
  }

  let body: Record<string, unknown>;
  try {
    body = JSON.parse(await req.text());
  } catch {
    return new Response("bad json", { status: 400 });
  }

  const evt = (body.event ?? {}) as Record<string, unknown>;
  const id = String(evt.id ?? "");
  const type = String(evt.type ?? "").toUpperCase();
  if (!id) {
    return new Response("missing event id", { status: 400 });
  }

  try {
    if (await alreadyProcessed(id)) {
      return Response.json({ ok: true, duplicate: true });
    }

    const userId = String(evt.app_user_id ?? "");

    // TRANSFER (Q27): resync BOTH accounts from RevenueCat. The old account
    // downgrades when it no longer has an active entitlement; both are audited
    // by apply_subscription_state.
    if (type === "TRANSFER") {
      const ids = transferIds(evt, userId);
      if (ids.length === 0) {
        await markProcessed(id, type);
        return Response.json({ ok: true, skipped: "no_uuid_transfer_ids" });
      }
      for (const target of ids) {
        await resyncUser(target, type);
      }
      await markProcessed(id, type);
      return Response.json({ ok: true, transferred: ids.length });
    }

    if (!UUID_RE.test(userId)) {
      // Not a Supabase user (anonymous/alias) — record + ack, nothing to sync.
      await markProcessed(id, type);
      return Response.json({ ok: true, skipped: "non_uuid_app_user_id" });
    }

    if (IMMEDIATE_FREE.has(type)) {
      // REFUND/chargeback: downgrade now, bypassing the 24h grace.
      await applyState(userId, "free", null, type);
    } else if (GRACE_EVENTS.has(type)) {
      // PAUSED/BILLING_ISSUE: later of stored expiry or event + 7 days.
      await applyGrace(userId, type, eventAtISO(evt));
    } else if (TIER_EVENTS.has(type) || RESET_EVENTS.has(type)) {
      // Tier-affecting events resync STRICTLY from the RevenueCat v2 customer
      // record — the event payload is never trusted for the tier. A failed
      // resync throws → recorded as a webhook_failure and ACKed 200 (we own
      // the retry queue; RC must not retry-storm).
      await resyncUser(userId, type);
    }
    // IGNORED / unknown events: ack (future-proofing) without a state change.

    await markProcessed(id, type);
    return Response.json({ ok: true });
  } catch (err) {
    await recordFailure(id, type, body, err);
    // 200 on handled failure: RC must not retry-storm; we own the retry queue.
    return Response.json({ ok: false, queued: true }, { status: 200 });
  }
});
