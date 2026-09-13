-- ============================================================
-- ScrollSense  views.sql
-- Deliverable G.1 — Five consumer views
-- Run AFTER schema.sql and generate_data.py
-- ============================================================

PRAGMA foreign_keys = ON;

-- ============================================================
-- VIEW SPECIFICATION SUMMARY
-- Consumer       | Columns exposed        | Hidden           | Depends on B.2 strategy
-- mobile client  | handle, display_name,  | auth_value,      | AccountStatusPeriod (V)
--                |   follower_count       |   auth_type      |
-- Trust & Safety | video_id, current_state| decided_at, ...  | ModerationDecision (A)
-- Growth         | creator, tier          | validity periods | CreatorTierPeriod (V)
-- Growth analysts| video, day, metrics    | raw segments     | ViewSegment (A), Like (A)
-- Finance        | turn, cost breakdown   | raw rates        | ModelPricing (V), Turn
-- ============================================================

-- ------------------------------------------------------------
-- v_public_profile
-- Consumer: mobile client
-- Exposes: user_id, handle, display_name, follower_count
--   user_id is exposed so the mobile client can link to profiles;
--   it does not expose auth_value or auth_type.
-- Deliberately hidden: auth_value (phone number / Google identifier),
--   auth_type, created_at.
-- Excluded: accounts whose CURRENT status is not 'active'
--   (deactivated accounts and accounts inside the 30-day
--    deletion window must be invisible to the mobile client).
-- Storage dependency hidden: AccountStatusPeriod uses validity
--   intervals (V strategy); the view consumer never sees this.
-- Updatability: SQLite views are always read-only.  In PostgreSQL
--   this view would be close to updatable (AppUser is the key-
--   preserved base) but the aggregate and joins would require an
--   INSTEAD OF trigger.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_public_profile;
CREATE VIEW v_public_profile AS
SELECT  u.user_id,
        u.handle,
        u.display_name,
        -- Count only followers whose follow is currently active (ended_at IS NULL)
        -- AND whose own account is currently active.
        -- COUNT(follower_status.user_id) counts non-NULL matches only,
        -- so inactive-follower rows (where the LEFT JOIN found no active
        -- status row) contribute 0 rather than being counted.
        COUNT(follower_status.user_id) AS follower_count
FROM    AppUser AS u
-- Only include accounts whose current status is 'active'.
-- "Current" = the AccountStatusPeriod row with valid_to IS NULL.
-- A user with no AccountStatusPeriod row is also excluded (INNER JOIN).
JOIN    AccountStatusPeriod AS asp
        ON  asp.user_id  = u.user_id
        AND asp.valid_to IS NULL
        AND asp.status   = 'active'
-- Count only followers whose follow relationship is currently active
-- (ended_at IS NULL) and whose own account is also active.
LEFT JOIN Follow AS f
        ON  f.followee_id = u.user_id
        AND f.ended_at   IS NULL
LEFT JOIN AccountStatusPeriod AS follower_status
        ON  follower_status.user_id  = f.follower_id
        AND follower_status.valid_to IS NULL
        AND follower_status.status   = 'active'
GROUP   BY u.user_id, u.handle, u.display_name;

-- ------------------------------------------------------------
-- v_video_current_state
-- Consumer: Trust & Safety
-- Exposes: video_id, current_state
-- "Current state in one lookup" — achieved by the index on
--   (video_id, decided_at DESC) created in schema.sql
-- Storage dependency hidden: ModerationDecision is append-only
--   (A strategy); the view presents only the latest decision.
--   The consumer never needs to know that history is retained.
-- Updatability: NOT updatable — derived from an aggregate
--   (MAX) over a table other than Video itself.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_video_current_state;
CREATE VIEW v_video_current_state AS
WITH LatestDecision AS (
    SELECT  video_id,
            MAX(decided_at) AS latest_at
    FROM    ModerationDecision
    GROUP   BY video_id
)
SELECT  v.video_id,
        COALESCE(md.new_state, 'pending') AS current_state
        -- Videos with no ModerationDecision row yet are treated as
        -- pending; this handles the edge case of a video uploaded
        -- but not yet processed by the classifier.
FROM    Video AS v
LEFT JOIN LatestDecision AS ld
        ON  ld.video_id = v.video_id
LEFT JOIN ModerationDecision AS md
        ON  md.video_id   = ld.video_id
        AND md.decided_at = ld.latest_at;

-- ------------------------------------------------------------
-- v_creator_tier_current
-- Consumer: Growth
-- Exposes: user_id (creator), current_tier
-- Storage dependency hidden: CreatorTierPeriod uses validity
--   intervals (V strategy); the view presents only current tier.
-- A creator with an active CreatorPeriod but no CreatorTierPeriod
--   row yet is included with current_tier = NULL (newly activated
--   creator not yet assigned a tier).
-- Updatability: NOT updatable — join across multiple tables.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_creator_tier_current;
CREATE VIEW v_creator_tier_current AS
SELECT  cp.user_id,
        ctp.tier AS current_tier
FROM    CreatorPeriod AS cp
-- LEFT JOIN must appear before WHERE in SQL syntax.
LEFT JOIN CreatorTierPeriod AS ctp
        ON  ctp.creator_period_id = cp.creator_period_id
        AND ctp.valid_to          IS NULL
-- Filter to current creators after the join so that creators with
-- no tier row still appear (current_tier = NULL).
WHERE   cp.valid_to IS NULL;
-- One row per current creator.
-- current_tier is NULL for creators not yet assigned a tier.

-- ------------------------------------------------------------
-- v_video_daily_engagement
-- Consumer: Growth analysts
-- Per video per day: impressions, views, watch_seconds, net_likes
-- CRITICAL: days with impressions but no engagement MUST appear
--   with zeros — not be omitted.  This is achieved by using
--   Impression as the spine and LEFT JOINing ViewSegment and Like.
-- Grain: one row per (video_id, day).
-- Storage dependencies hidden: ViewSegment (A), Like (A),
--   LikeRetraction (A); the consumer sees only aggregated metrics.
-- Updatability: NOT updatable — aggregation over multiple tables.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_video_daily_engagement;
CREATE VIEW v_video_daily_engagement AS
WITH ImpressionDay AS (
    -- Spine: every (video_id, day) that has at least one impression.
    -- This ensures days with impressions but zero views still appear.
    SELECT  video_id,
            date(impressed_at) AS day,
            COUNT(*)           AS impression_count
    FROM    Impression
    GROUP   BY video_id, date(impressed_at)
),
ViewDay AS (
    -- Aggregate watch time at impression level first to avoid fan-out.
    -- A single impression with N segments would otherwise produce N rows
    -- and inflate watch_seconds by a factor of N.
    SELECT  i.video_id,
            date(i.impressed_at)                                 AS day,
            COUNT(DISTINCT i.impression_id)                      AS view_count,
            SUM(vs.segment_end_ms - vs.segment_start_ms) / 1000.0 AS watch_seconds
    FROM    Impression  AS i
    JOIN    ViewSegment AS vs ON vs.impression_id = i.impression_id
    GROUP   BY i.video_id, date(i.impressed_at)
),
LikeDay AS (
    -- Net likes = likes - retractions on the same day.
    -- A like and its retraction may fall on different days;
    -- this counts the like on the day it was given and
    -- subtracts retractions on the day they occurred.
    SELECT  video_id,
            date(liked_at) AS day,
            COUNT(*)       AS likes_given
    FROM    Like
    GROUP   BY video_id, date(liked_at)
),
RetractionDay AS (
    SELECT  l.video_id,
            date(lr.retracted_at) AS day,
            COUNT(*)              AS retractions_given
    FROM    LikeRetraction AS lr
    JOIN    Like           AS l ON l.like_id = lr.like_id
    GROUP   BY l.video_id, date(lr.retracted_at)
)
SELECT  id.video_id,
        id.day,
        id.impression_count,
        COALESCE(vd.view_count,        0)    AS view_count,
        ROUND(COALESCE(vd.watch_seconds, 0), 3) AS watch_seconds,
        COALESCE(ld.likes_given,       0)
            - COALESCE(rd.retractions_given, 0) AS net_likes
FROM    ImpressionDay AS id
LEFT JOIN ViewDay      AS vd ON  vd.video_id = id.video_id AND vd.day = id.day
LEFT JOIN LikeDay      AS ld ON  ld.video_id = id.video_id AND ld.day = id.day
LEFT JOIN RetractionDay AS rd ON rd.video_id = id.video_id AND rd.day = id.day
ORDER   BY id.video_id, id.day;

-- ------------------------------------------------------------
-- v_turn_cost
-- Consumer: Finance
-- Cost per turn, computed against the price in force AT THE
--   TIME OF THE TURN — not the current price.
-- Key design: Turn.pricing_id is a FK frozen at insert time
--   to the ModelPricing row whose validity interval covered
--   Turn.responded_at.  This means a simple JOIN (not a range
--   subquery) recovers the historical rate.
-- If this were computed against the current price row, a vendor
--   repricing would retroactively change all past cost reports,
--   violating the Finance requirement from §2.5.
-- Storage dependency hidden: ModelPricing uses validity intervals
--   (V strategy); the view consumer only sees the final cost.
-- Updatability: NOT updatable — aggregation and join across
--   multiple tables with no single key-preserved base table.
-- ------------------------------------------------------------
DROP VIEW IF EXISTS v_turn_cost;
CREATE VIEW v_turn_cost AS
SELECT  t.turn_id,
        t.session_id,
        t.model_name,
        t.responded_at,
        mp.vendor,
        mp.valid_from   AS price_valid_from,
        mp.valid_to     AS price_valid_to,
        t.input_tokens,
        t.output_tokens,
        t.cached_tokens,
        mp.input_rate,
        mp.output_rate,
        mp.cached_input_rate,
        -- Cost in the same unit as the rates (typically USD per token).
        -- Cached tokens are charged at cached_input_rate, NOT at input_rate.
        -- The non-cached portion of input is (input_tokens - cached_tokens).
        -- Using input_tokens * input_rate + cached_tokens * cached_input_rate
        -- would double-charge cached tokens (once at input_rate, once at
        -- cached_input_rate), so the correct formula subtracts cached_tokens
        -- from the input count first.
        ROUND(
            (t.input_tokens - t.cached_tokens) * mp.input_rate
          + t.cached_tokens                    * mp.cached_input_rate
          + t.output_tokens                    * mp.output_rate,
        8) AS turn_cost
FROM    Turn         AS t
JOIN    ModelPricing AS mp ON mp.pricing_id = t.pricing_id;
-- One row per turn.
-- turn_cost is computed against the rate frozen at insert time;
-- a subsequent vendor price change does not alter this value.
-- Finance queries can aggregate: SUM(turn_cost) per session,
-- per month, or per user without any further rate lookups.

