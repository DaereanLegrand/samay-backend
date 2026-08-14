// Samay — edge-runtime main service BOOT PLACEHOLDER (M-07, 2026-08-10).
//
// This is NOT a business function. The pinned supabase/edge-runtime:v1.74.0
// image (compose service `functions`) requires a main-service entrypoint:
// without `index.ts` in the --main-service directory the main worker boot
// fails (verified in edge-runtime v1.74.0 source, crates/base/src/runtime/
// mod.rs — a missing entrypoint falls back to the directory URL, which
// cannot be loaded as a module) and the container crash-loops, breaking
// `docker compose up -d --wait`.
//
// The real functions land with EEDG (docs/specs/steps/phase-05-events/
// EEDG-edge-functions-event-lifecycle.md). Until then every request to
// `/functions/v1/*` (Kong -> edge-runtime) returns this placeholder
// response. Remove/replace this file when EEDG ships.
Deno.serve(() => new Response("ok", { status: 200 }));
