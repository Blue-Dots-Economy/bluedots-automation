-- helmcharts/dpg/charts/api/files/provision_service_users.sql
--
-- Idempotent upsert for internal/integrating service users + apikeys. Applied
-- by the helm migrate-job's provision container, after migrate-ddl has created
-- the better-auth tables, on every install AND upgrade.
--
-- Source of truth for each raw key is the api k8s Secret; this file derives the
-- SHA-256(key) hash that better-auth's @better-auth/api-key looks up at verify
-- time. Re-running with a rotated key UPDATEs that row in place — the old key
-- stops working immediately. Rows are keyed per service user, so rotating one
-- service's key never touches another's.
--
-- Service users provisioned (add a row to the VALUES list below to extend):
--   aggregator-dpg        ← AGGREGATOR_DPG_API_KEY  (aggregator → signals api)
--   signals-search-client ← SIGNALS_SEARCH_API_KEY  (signals api → signals-search
--                           POST /v1/relevance, which backs match-score since
--                           signals-dpg#352 retired the dpg_scoring provider.
--                           signals-search verifies it with authenticateApiKey
--                           against this same `apikey` table, using an identical
--                           base64url(sha256(raw)) hash — so seeding here is all
--                           that is required on the callee side.)
--   raya-voice-bot        ← RAYA_VOICE_BOT_API_KEY  (raya voice bot → signals api.
--                           Same inbound direction as aggregator-dpg above. This is
--                           the api-key path for the bot that also has the `voice-dpg`
--                           Keycloak client-credentials client; the two credentials are
--                           independent and rotate separately.)
--
-- Required psql variables:  aggregator_dpg_api_key, signals_search_api_key,
--                           raya_voice_bot_api_key
-- Invoked from migrate-job.yaml as:
--   psql -v aggregator_dpg_api_key="$AGGREGATOR_DPG_API_KEY" \
--        -v signals_search_api_key="$SIGNALS_SEARCH_API_KEY" \
--        -v raya_voice_bot_api_key="$RAYA_VOICE_BOT_API_KEY" \
--        -f /sql/provision_service_users.sql
--
-- Requires pgcrypto (digest, gen_random_uuid), provisioned by common-services.
--
-- Hash format must match @better-auth/api-key `defaultKeyHasher`:
--   base64url(sha256(raw_key))  — unpadded, '+/' → '-_'.

\set ON_ERROR_STOP on

-- psql `:'var'` interpolation does NOT expand inside $$...$$ dollar-quoted
-- blocks. Stash each raw key in a session GUC outside the DO block, read it
-- back inside via current_setting().
SELECT set_config('signals.aggregator_dpg_api_key', :'aggregator_dpg_api_key', false);
SELECT set_config('signals.signals_search_api_key', :'signals_search_api_key', false);
SELECT set_config('signals.raya_voice_bot_api_key', :'raya_voice_bot_api_key', false);

DO $$
DECLARE
  _svc         record;
  _raw_key      text;
  _hashed       text;
  _key_prefix   text := 'sk_signals_';
  _org_id       text;
  _user_id      text;
  _existing_key text;
BEGIN
  FOR _svc IN
    SELECT * FROM (VALUES
      ('aggregator-dpg',        'aggregator-dpg-svc@signals.local',        'signals.aggregator_dpg_api_key'),
      ('signals-search-client', 'signals-search-client-svc@signals.local', 'signals.signals_search_api_key'),
      ('raya-voice-bot',        'raya-voice-bot-svc@signals.local',        'signals.raya_voice_bot_api_key')
    ) AS t(org_slug, user_email, guc)
  LOOP
    -- Reset per iteration: SELECT ... INTO assigns NULL when no row matches,
    -- but being explicit keeps a future edit from leaking state across rows.
    _org_id       := NULL;
    _user_id      := NULL;
    _existing_key := NULL;

    _raw_key := current_setting(_svc.guc, true);
    IF _raw_key IS NULL OR _raw_key = '' THEN
      RAISE EXCEPTION '% is not set (psql variable missing)', _svc.guc;
    END IF;
    IF length(_raw_key) < 32 THEN
      RAISE EXCEPTION '% is too short (% chars); need >= 32', _svc.guc, length(_raw_key);
    END IF;

    _hashed := translate(
      rtrim(encode(digest(_raw_key, 'sha256'), 'base64'), '='),
      '+/', '-_'
    );

    -- 1. organization (match by slug)
    SELECT id INTO _org_id FROM "organization" WHERE slug = _svc.org_slug;
    IF _org_id IS NULL THEN
      _org_id := 'org_' || gen_random_uuid();
      INSERT INTO "organization" (id, slug, name, type, created_at)
      VALUES (_org_id, _svc.org_slug, _svc.org_slug || ' (network service)', 'network_service', now());
    END IF;

    -- 2. user (match by email)
    SELECT id INTO _user_id FROM "user" WHERE email = _svc.user_email;
    IF _user_id IS NULL THEN
      _user_id := 'usr_' || gen_random_uuid();
      INSERT INTO "user" (id, email, name, email_verified, created_at, updated_at)
      VALUES (_user_id, _svc.user_email, _svc.org_slug, true, now(), now());
    END IF;

    -- 3. member (match by user_id + organization_id)
    IF NOT EXISTS (
      SELECT 1 FROM "member"
      WHERE user_id = _user_id AND organization_id = _org_id
    ) THEN
      INSERT INTO "member" (id, user_id, organization_id, role, created_at)
      VALUES ('mem_' || gen_random_uuid(), _user_id, _org_id, 'service', now());
    END IF;

    -- 4. apikey (one per service user). Rotation = hash differs → UPDATE in place.
    SELECT key INTO _existing_key FROM "apikey" WHERE user_id = _user_id LIMIT 1;
    IF _existing_key IS NULL THEN
      INSERT INTO "apikey" (
        id, config_id, name, start, reference_id, prefix, key, user_id,
        enabled, rate_limit_enabled, created_at, updated_at
      )
      VALUES (
        'key_' || gen_random_uuid(),
        'default',
        _svc.org_slug,
        substring(_raw_key from 1 for 6),
        _user_id,
        _key_prefix,
        _hashed,
        _user_id,
        true,
        false,
        now(),
        now()
      );
    ELSIF _existing_key <> _hashed THEN
      UPDATE "apikey"
         SET key = _hashed,
             start = substring(_raw_key from 1 for 6),
             prefix = _key_prefix,
             enabled = true,
             updated_at = now()
       WHERE user_id = _user_id;
    END IF;
  END LOOP;
END
$$;
