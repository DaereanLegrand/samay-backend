// Samay — RevenueCat webhook handler (RCBH).
//
// Endpoint: POST /functions/v1/revenuecat-webhook  (via Kong -> edge-runtime)
// Auth: the shared secret configured as the RevenueCat webhook's Authorization
//       header (env REVENUECAT_WEBHOOK_SECRET). Fail-closed when unset/blank.
//
// Contract (docs/specs/steps/phase-12-monetization-subscriptions/
// RCBH-revenuecat-webhook-handler.md):
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
// CANCELLATION keeps access until EXPIRATION; the rest carry no tier change.
const IGNORED_EVENTS = new Set([
  "CANCELLATION",
  "BILLING_ISSUE",
  "SUBSCRIPTION_PAUSED",
  "TRANSFER",
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

// Resolve the subscription tier from the payload's entitlements (preferred) or
// the product id. Returns "free" when the event carries no paid entitlement
// (e.g. a consumable).
function resolveTier(evt: Record<string, unknown>): "pro" | "vip" | "free" {
  const ent = Array.isArray(evt.entitlement_ids)
    ? (evt.entitlement_ids as unknown[]).map((e) => String(e).toLowerCase())
    : [];
  if (ent.includes("vip")) return "vip";
  if (ent.includes("pro")) return "pro";
  const product = String(evt.product_id ?? "").toLowerCase();
  if (product.includes("vip")) return "vip";
  if (product.includes("pro")) return "pro";
  return "free";
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
    if (!UUID_RE.test(userId)) {
      // Not a Supabase user (anonymous/alias) — record + ack, nothing to sync.
      await markProcessed(id, type);
      return Response.json({ ok: true, skipped: "non_uuid_app_user_id" });
    }

    if (RESET_EVENTS.has(type)) {
      await applyState(userId, "free", null, type);
    } else if (TIER_EVENTS.has(type)) {
      const tier = resolveTier(evt);
      if (tier !== "free") {
        const ms = Number(evt.expiration_at_ms ?? 0);
        const expires = ms > 0 ? new Date(ms).toISOString() : null;
        await applyState(userId, tier, expires, type);
      }
      // tier === "free" (e.g. a consumable) -> no subscription change.
    } else if (!IGNORED_EVENTS.has(type)) {
      // Unknown event type: ack (future-proofing) without a state change.
    }

    await markProcessed(id, type);
    return Response.json({ ok: true });
  } catch (err) {
    await recordFailure(id, type, body, err);
    // 200 on handled failure: RC must not retry-storm; we own the retry queue.
    return Response.json({ ok: false, queued: true }, { status: 200 });
  }
});
