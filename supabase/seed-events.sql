-- ============================================================================
-- Samay — seed-events.sql
--
-- Seeds N random demo events WITHIN 100 km of Arequipa into the retained
-- `events` tables. The Events feature was removed from the client in slim-prod
-- (client grants revoked in `300_slim/05_revoke_removed.sql`), so this only
-- helps when exercising `search_events` via service_role/psql.
--
-- TESTING STACK ONLY. Never run this against the prod `supabase/` stack.
-- Run against the local `testing-local` Postgres (host port 54392):
--
--   PGPASSWORD=postgres psql -h localhost -p 54392 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f supabase/seed-events.sql
--
-- Idempotent: every prior `[demo-arq]` event (and its host rows, via FK
-- cascade) is removed first, so re-running replaces the previous batch.
-- Regular events are untouched.
--
-- Creator/host: `tester` when it exists, otherwise the newest non-deleted
-- user. If there are no users at all, nothing is inserted (notice raised) —
-- seed users first (`make seed`).
-- ============================================================================

\set ON_ERROR_STOP on

DO $seed$
DECLARE
  -- ── Knobs ──────────────────────────────────────────────────────────────
  c_lat    double precision := -16.3988;  -- Arequipa center
  c_lng    double precision := -71.5369;
  max_km   double precision := 100.0;     -- server hard-cap (131_events_search)
  n_events int              := 30;        -- how many demo events to create

  -- ── Working vars ───────────────────────────────────────────────────────
  v_host   uuid;
  v_cap    int;
  v_id     uuid;
  i        int;
  r_km     double precision;
  theta    double precision;
  e_lat    double precision;
  e_lng    double precision;
  e_type   public.event_type;
  e_status public.event_status;
  e_join   public.join_mode;
  e_name   text;
  e_pool   int;
  e_starts timestamptz;
  e_ends   timestamptz;
BEGIN
  SELECT u.id INTO v_host
  FROM public.users u
  WHERE u.deleted_at IS NULL
  ORDER BY (u.username = 'tester1') DESC, u.created_at DESC
  LIMIT 1;

  IF v_host IS NULL THEN
    RAISE NOTICE 'seed-events: no users found — seed users first; nothing inserted';
    RETURN;
  END IF;

  -- The capacity trigger (`assert_event_capacity`) rejects any capacity above
  -- the CREATOR's subscription-tier cap, read from app_config — mirror it here.
  SELECT COALESCE(value::integer, 7) INTO v_cap
  FROM public.app_config
  WHERE key = (
    SELECT CASE (
      SELECT subscription_tier FROM public.users WHERE id = v_host
    )
      WHEN 'pro'::public.subscription_tier THEN 'events.pro_max_attendees'
      WHEN 'vip'::public.subscription_tier THEN 'events.vip_max_attendees'
      ELSE 'events.free_max_attendees'
    END
  );
  IF v_cap IS NULL THEN
    v_cap := 7;
  END IF;

  DELETE FROM public.events WHERE name LIKE '[demo-arq]%';

  FOR i IN 1..n_events LOOP
    -- Uniform over the disk: r = R·√u is area-uniform, θ uniform. Convert the
    -- km offset to degrees (111.320 km per degree of latitude).
    r_km  := max_km * sqrt(random());
    theta := 2 * pi() * random();
    e_lat := c_lat + (r_km * cos(theta)) / 111.320;
    e_lng := c_lng + (r_km * sin(theta)) / (111.320 * cos(radians(c_lat)));

    e_type := (ARRAY['juerga', 'tono', 'casual'])[
      1 + floor(random() * 3)::int
    ]::public.event_type;
    e_status := (
      CASE WHEN random() < 0.25 THEN 'live' ELSE 'upcoming' END
    )::public.event_status;
    e_join := (ARRAY['open', 'approval'])[
      1 + floor(random() * 2)::int
    ]::public.join_mode;
    -- `casual` must keep preshards_pool = 0 (check_casual_no_preshards).
    e_pool := CASE
      WHEN e_type = 'casual' THEN 0
      ELSE (1 + floor(random() * 20)::int) * 250
    END;
    e_starts := now()
      + (1 + floor(random() * 30)::int) * interval '1 day'
      + floor(random() * 24)::int * interval '1 hour';
    e_ends := e_starts + (3 + floor(random() * 9)::int) * interval '1 hour';
    e_name := format(
      '[demo-arq] %s #%s · %s km',
      (ARRAY['Juerga', 'Previa', 'Tono', 'Encuentro', 'Fiesta'])[
        1 + floor(random() * 5)::int
      ],
      i,
      round(r_km)::int
    );

    INSERT INTO public.events (
      name, description, type, created_by_user_id, group_id,
      location_name, location_lat, location_lng, starts_at, ends_at,
      join_mode, preshards_pool, preshards_cap_per_user,
      preshards_remainder_action, capacity, status
    ) VALUES (
      e_name,
      'Evento demo para probar el descubrimiento y el radio (Arequipa).',
      e_type,
      v_host,
      NULL,
      format('Arequipa · %s km del centro', round(r_km)::int),
      e_lat::numeric,
      e_lng::numeric,
      e_starts,
      e_ends,
      e_join,
      e_pool,
      CASE WHEN e_type = 'casual' THEN NULL ELSE 250 END,
      CASE
        WHEN e_type = 'casual' THEN NULL
        ELSE 'redistribute'::public.preshard_remainder_action
      END,
      1 + floor(random() * v_cap)::int,
      e_status
    )
    RETURNING id INTO v_id;

    INSERT INTO public.event_hosts (event_id, user_id, role)
    VALUES (v_id, v_host, 'host');
  END LOOP;

  RAISE NOTICE 'seed-events: inserted % demo events within % km of Arequipa',
    n_events, max_km;
END
$seed$;

-- Sanity report: count + nearest/farthest distance from the Arequipa center.
SELECT count(*) AS demo_events,
       round(min(public.haversine_km(
         -16.3988, -71.5369,
         location_lat::double precision, location_lng::double precision
       ))) AS min_km,
       round(max(public.haversine_km(
         -16.3988, -71.5369,
         location_lat::double precision, location_lng::double precision
       ))) AS max_km
FROM public.events
WHERE name LIKE '[demo-arq]%';
