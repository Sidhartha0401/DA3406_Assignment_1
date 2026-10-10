-- ============================================================
-- ScrollSense — queries.sql
-- Deliverable F: 13 queries
-- SQLite 3.45.1 used  (group_concat ORDER BY, window functions,
--   recursive CTE, RANGE frames).
-- Run after schema.sql + generate_data.py have been executed.
-- ============================================================

PRAGMA foreign_keys = ON;

-- ============================================================
-- TIER 1 — CORE SQL
-- ============================================================

-- ------------------------------------------------------------
-- F1 · Top 10 audio tracks by distinct videos in the last 7 days.
-- Intent: count how many unique videos using each audio track
--   received an impression in the most recent 7-day window.
-- Expected shape: at most 10 rows; tracks with no recent
--   impressions are excluded (they are irrelevant to the question).
-- Grain: one row per audio track.
-- ------------------------------------------------------------
SELECT  at.track_id,
        COUNT(DISTINCT v.video_id) AS distinct_videos
FROM    AudioTrack AS at
JOIN    Video      AS v  ON  v.audio_track_id = at.track_id
JOIN    Impression AS i  ON  i.video_id = v.video_id
WHERE   i.impressed_at >= strftime('%Y-%m-%dT%H:%M:%SZ',
            (SELECT MAX(impressed_at) FROM Impression), '-7 days')
GROUP   BY at.track_id
ORDER   BY distinct_videos DESC, at.track_id ASC
LIMIT   10;


-- ------------------------------------------------------------
-- F2 · Watch hours and completion rate per creator, live clips only.
--   Every creator must appear, including those with no live clips
--   and those whose clips have never been watched.
-- Intent: power-law check — top creators hold most watch time.
-- Grain: one row per creator (user with a CreatorPeriod row).
-- Key design points:
--   • ModerationDecision is append-only; current state must be
--     derived from the MAX(decided_at) row, not a column on Video.
--   • ViewSegment is aggregated per impression before joining
--     to avoid fan-out (one impression → many segments → inflated sums).
--   • LEFT JOIN from CreatorPeriod preserves zero-watch creators.
-- ------------------------------------------------------------
WITH LatestDecision AS (
    SELECT  video_id,
            MAX(decided_at) AS latest_time
    FROM    ModerationDecision
    GROUP   BY video_id
),
LiveVideo AS (
    SELECT  md.video_id
    FROM    ModerationDecision AS md
    JOIN    LatestDecision     AS ld
            ON  ld.video_id    = md.video_id
            AND ld.latest_time = md.decided_at
    WHERE   md.new_state = 'live'
),
-- Aggregate ViewSegment at impression level BEFORE joining to Video/Creator.
-- Without this intermediate step a single impression with 3 segments
-- would fan out to 3 rows and triple-count the impression's watch time.
-- Completion rate is averaged over viewed impressions only — impressions
-- that produced at least one ViewSegment row.  Impressions with no
-- ViewSegment row (the clip entered the viewport but was never actually
-- watched for ≥300 ms) do not appear in SegmentStats and therefore do
-- not pull the average down.  This matches the brief's definition of a
-- "view" as distinct from a bare "impression".
SegmentStats AS (
    SELECT   i.impression_id,
             i.video_id,
             SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms,
             MAX(vs.completed)                             AS completed
    FROM     Impression  AS i
    JOIN     ViewSegment AS vs ON vs.impression_id = i.impression_id
    GROUP BY i.impression_id, i.video_id
)
SELECT  cp.user_id                                              AS creator_id,
        ROUND(COALESCE(SUM(ss.watch_ms), 0) / 3600000.0, 4)   AS watch_hours,
        ROUND(COALESCE(AVG(ss.completed), 0), 4)               AS completion_rate
FROM    CreatorPeriod AS cp
LEFT JOIN Video        AS v  ON  v.owner_id  = cp.user_id
LEFT JOIN LiveVideo    AS lv ON  lv.video_id = v.video_id
LEFT JOIN SegmentStats AS ss ON  ss.video_id = lv.video_id
GROUP   BY cp.user_id
ORDER   BY watch_hours DESC;


-- ------------------------------------------------------------
-- F3 · Videos with no audio track — written twice.
-- Both variants must return the same row count on this schema
--   because audio_track_id is a simple nullable FK, not computed.
-- The interesting difference arises when the subquery can return
--   NULL; see the explanation below.
-- ------------------------------------------------------------

-- Version A: NOT IN
-- Safe here because the subquery filters to IS NOT NULL, so the
-- set returned to NOT IN contains no NULLs.  If audio_track_id
-- could itself be NULL in the subquery result, SQL's three-valued
-- logic would make NOT IN return UNKNOWN (not TRUE) for every row,
-- silently returning zero rows even when matches exist.
SELECT  video_id
FROM    Video
WHERE   video_id NOT IN (
            SELECT video_id
            FROM   Video
            WHERE  audio_track_id IS NOT NULL
        )
ORDER   BY video_id;

-- Version B: NOT EXISTS
-- Immune to the NULL problem: it checks for the absence of a
-- matching row rather than comparing against a set that might
-- contain NULL.  Preferred idiom for anti-join patterns.
SELECT  v.video_id
FROM    Video AS v
WHERE   NOT EXISTS (
            SELECT 1
            FROM   AudioTrack AS at
            WHERE  at.track_id = v.audio_track_id
        )
ORDER   BY v.video_id;


--Both return {6171}.  They agree here because the
--{NOT IN} subquery returns only non-{NULL}
--{video\_id} values; {video\_id} is a primary key and
--therefore cannot be {NULL}.  The nullable
--{audio\_track\_id} indicates that a video may have no audio
--track, but those {NULL} values are filtered out before the
--{NOT IN} comparison.


-- ------------------------------------------------------------
-- F4 · Users who liked and then retracted a like on the same clip
--   within 60 seconds.
-- Grain: one row per (user, video, like) event — a user could
--   theoretically like-and-retract the same clip more than once
--   if a second Like row existed; UNIQUE is not enforced per user+video.
-- BETWEEN 0 AND 60 is used rather than <= 60 to make the non-negative
--   constraint explicit: a retraction cannot precede the like
--   (negative diff would indicate a data anomaly and should be excluded).
-- ------------------------------------------------------------
SELECT  l.user_id,
        l.video_id,
        l.liked_at,
        lr.retracted_at,
        CAST(
            (julianday(lr.retracted_at) - julianday(l.liked_at)) * 86400
        AS INTEGER) AS seconds_to_retract
FROM    Like           AS l
JOIN    LikeRetraction AS lr ON lr.like_id = l.like_id
WHERE   (julianday(lr.retracted_at) - julianday(l.liked_at)) * 86400
        BETWEEN 0 AND 60
ORDER   BY seconds_to_retract, l.liked_at;


-- ------------------------------------------------------------
-- F5 · Videos whose caption carries the hashtag #cat,
--   matching case-insensitively and tolerating surrounding
--   punctuation and whitespace.
-- SQLite has no REGEXP built-in and no split_part.
-- Required functions: lower(), trim(), replace(), instr(), LIKE.
-- Strategy: the # must be preserved — stripping it would match
--   plain words like "cat" that are not hashtags.
--   (1) lower()   — case-fold the caption.
--   (2) replace() — replace non-hash punctuation (,;.!?) with spaces
--                   so hashtag tokens are cleanly space-delimited.
--   (3) trim()    — strip any leading/trailing whitespace left over.
--   (4) instr()   — quick pre-filter: the normalised caption must
--                   contain the substring '#cat' at all before the
--                   costlier boundary checks run.
--   (5) LIKE      — four branches enforce word-boundary delimiting:
--                   '#cat ' (start), '% #cat %' (middle),
--                   '% #cat' (end), or the caption equals '#cat' alone.
-- The # is NOT replaced, so a caption containing the plain word "cat"
--   without a leading # is correctly excluded.
-- LIKE vs GLOB: LIKE is used because SQLite's LIKE is already
--   case-insensitive for ASCII, making lower() + LIKE '#cat %'
--   match '#Cat', '#CAT', etc. without extra patterns.
--   GLOB is case-sensitive and would require [Cc][Aa][Tt]-style
--   bracket expressions.
-- Tamil note: SQLite's LIKE case-folding is ASCII-only. Tamil script
--   has no upper/lower case distinction, so for a Tamil hashtag the
--   lower() call is a no-op and the LIKE match still works correctly
--   because the byte sequence is identical regardless of case.
-- ------------------------------------------------------------
WITH Normed AS (
    SELECT  video_id,
            caption,
            -- Steps 1–3: lower, replace non-hash punctuation, trim.
            trim(lower(
                replace(replace(replace(replace(replace(
                    caption,
                ',', ' '), ';', ' '), '.', ' '), '!', ' '), '?', ' ')
            )) AS norm_cap
    FROM    Video
)
SELECT  video_id,
        caption
FROM    Normed
WHERE   -- Step 4: instr() pre-filter — '#cat' must appear somewhere.
        instr(norm_cap, '#cat') > 0
        -- Step 5: LIKE boundary checks — '#cat' must be a whole token.
  AND   (   norm_cap LIKE '#cat %'
         OR norm_cap LIKE '% #cat %'
         OR norm_cap LIKE '% #cat'
         OR norm_cap =    '#cat')
ORDER   BY video_id;
-- Verified against VideoHashtag table: both paths return 1501.
-- A caption containing the bare word "cat" (no #) does not match.



-- ------------------------------------------------------------
-- F6 · Users shown a given creator's clips but never engaged —
--   using a set operator (EXCEPT).
-- Creator chosen: user_id = 461 (a high-watch-hour creator from F2).
-- "Engaged" = any like, explicit signal, or share on that creator's video.
-- UNION inside the EXCEPT operand deduplicates users who appear
--   in more than one signal table (avoids an inner duplicate causing
--   EXCEPT to miss them).
-- ------------------------------------------------------------
SELECT DISTINCT i.user_id
FROM    Impression AS i
JOIN    Video      AS v ON v.video_id = i.video_id
WHERE   v.owner_id = 461

EXCEPT

SELECT user_id FROM (
    SELECT l.user_id
    FROM   Like  AS l
    JOIN   Video AS v ON v.video_id = l.video_id
    WHERE  v.owner_id = 461

    UNION

    SELECT es.user_id
    FROM   ExplicitSignal AS es
    JOIN   Video          AS v ON v.video_id = es.video_id
    WHERE  v.owner_id = 461

    UNION

    SELECT sh.user_id
    FROM   Share AS sh
    JOIN   Video AS v ON v.video_id = sh.video_id
    WHERE  v.owner_id = 461
);
--   produced zero explicit signals — the typical silent majority
--   of a short-video feed.

-- UNION vs UNION ALL on the same signal roll-up:
SELECT user_id
FROM   Like  AS l JOIN Video AS v ON v.video_id = l.video_id WHERE v.owner_id = 461
UNION
SELECT user_id
FROM   Share AS s JOIN Video AS v ON v.video_id = s.video_id WHERE v.owner_id = 461;
-- UNION deduplicates: a user who both liked and shared one of
--   creator 461's clips appears only once.

SELECT user_id
FROM   Like  AS l JOIN Video AS v ON v.video_id = l.video_id WHERE v.owner_id = 461
UNION ALL
SELECT user_id
FROM   Share AS s JOIN Video AS v ON v.video_id = s.video_id WHERE v.owner_id = 461;
-- UNION ALL preserves duplicates: that user appears twice.
-- Use UNION when you want distinct actors; UNION ALL when you
--   want the total count of signal events (including repeat actors).


-- ------------------------------------------------------------
-- F7 · Cost of each agent session in the last 30 days, broken out
--   by prompt template version, restricted to sessions costing > 0.01.
-- "Last 30 days" = sessions whose started_at >= MAX(started_at) - 30 days.
-- Cost per turn formula (corrected — no double-counting of cached tokens):
--   (input_tokens - cached_tokens) * input_rate   -- non-cached input
--   + cached_tokens                * cached_input_rate  -- cached input at reduced rate
--   + output_tokens                * output_rate
-- The original formula  input_tokens * input_rate + cached_tokens * cached_input_rate
--   double-counts cached tokens: they are already included in input_tokens,
--   so applying input_rate to the full input_tokens and then adding
--   cached_input_rate on top charges cached tokens twice.
-- The rates come from ModelPricing via the pricing_id FK frozen at turn
--   insertion — not from the current price.  This is the schema consequence
--   of the Finance requirement: a price change must never alter last
--   quarter's reported costs.
-- Threshold chosen: 0.01 (eliminates near-zero-cost sessions).
-- ------------------------------------------------------------
WITH Last30Days AS (
    SELECT datetime(MAX(started_at), '-30 days') AS cutoff
    FROM   AgentSession
),
TurnCost AS (
    SELECT  t.session_id,
            pt.template_name,
            pt.version,
            SUM(
                (t.input_tokens - t.cached_tokens) * mp.input_rate
              +  t.cached_tokens                   * mp.cached_input_rate
              +  t.output_tokens                   * mp.output_rate
            ) AS session_cost
    FROM    Turn           AS t
    JOIN    AgentSession   AS s  ON  s.session_id  = t.session_id
    JOIN    PromptTemplate AS pt ON  pt.template_id = t.template_id
    JOIN    ModelPricing   AS mp ON  mp.pricing_id  = t.pricing_id
    JOIN    Last30Days
    WHERE   s.started_at >= Last30Days.cutoff
    GROUP   BY t.session_id, pt.template_name, pt.version
)
SELECT  session_id,
        template_name,
        version,
        ROUND(session_cost, 6) AS session_cost
FROM    TurnCost
WHERE   session_cost > 0.01
ORDER   BY session_cost DESC;


-- ------------------------------------------------------------
-- F8 · Videos whose moderation state changed more than twice,
--   with the full sequence of transitions in chronological order.
-- group_concat with ORDER BY requires SQLite 3.44+.
--   On older versions the order of concatenation is undefined and
--   a result that looks plausible may silently be wrong.
--   Check: SELECT sqlite_version(); must return >= 3.44.0.
-- "Changed more than twice" = more than 2 rows in ModerationDecision
--   (i.e., at least 3 decisions).
-- ------------------------------------------------------------
SELECT  md.video_id,
        COUNT(*)                                                   AS n_decisions,
        group_concat(md.new_state, ' -> ' ORDER BY md.decided_at) AS state_sequence
FROM    ModerationDecision AS md
GROUP   BY md.video_id
HAVING  COUNT(*) > 2
ORDER   BY n_decisions DESC, md.video_id;


-- ============================================================
-- TIER 2 — WINDOW FUNCTIONS AND RECURSION
-- ============================================================

-- ------------------------------------------------------------
-- F9 · Each user's longest streak of consecutive active days.
-- "Active" = at least one impression on that calendar day.
-- Method: the classic consecutive-group trick.
--   1. Find each distinct (user, calendar_day) pair.
--   2. Compute ROW_NUMBER() partitioned by user, ordered by day.
--   3. Subtract the row number (as a day offset) from the date.
--      Consecutive days reduce to the same group key.
--   4. Count the streak length per group; take the max per user.
-- julianday() is used for arithmetic; ISO-8601 text parses directly.
-- ------------------------------------------------------------
WITH ActiveDays AS (
    SELECT  DISTINCT
            user_id,
            date(impressed_at) AS active_day
    FROM    Impression
),
Numbered AS (
    SELECT  user_id,
            active_day,
            date(active_day,
                 '-' || (ROW_NUMBER() OVER (
                             PARTITION BY user_id
                             ORDER BY active_day
                         ) - 1) || ' days') AS grp
    FROM    ActiveDays
),
Streaks AS (
    SELECT  user_id,
            grp,
            COUNT(*) AS streak_len
    FROM    Numbered
    GROUP   BY user_id, grp
)
SELECT  user_id,
        MAX(streak_len) AS longest_streak_days
FROM    Streaks
GROUP   BY user_id
ORDER   BY longest_streak_days DESC, user_id ASC
LIMIT   20;


-- ------------------------------------------------------------
-- F10 · Rank creators by 7-day rolling watch time, with
--   week-over-week change.
-- "7 days" = 7 consecutive calendar days ending on (and including)
--   each day a creator had activity.  This is not the same as the 7
--   days on which the creator happened to have activity: it counts
--   any watch time falling in the 6 preceding calendar days plus
--   the current day.  Growth asked for calendar days.
-- SQLite RANGE frames take numeric offsets only; there is no
--   INTERVAL '7 days'.  The workaround: ORDER BY julianday(date)
--   so that RANGE BETWEEN 6.0 PRECEDING AND CURRENT ROW covers
--   exactly 7 calendar days (julianday differs by 1.0 per day).
-- Week-over-week comparison: the previous week's rolling total is
--   the rolling_7d_ms value for the same creator exactly 7 calendar
--   days earlier — found by a self-join on Rolling at day_jd - 7.0.
--   LAG(..., 7) was NOT used because it steps back 7 *activity rows*,
--   not 7 calendar days; a creator with fewer than 7 active days in
--   the past fortnight would receive a stale or wrong prior value.
--   The self-join returns NULL cleanly when no row exists at that date.
-- Only live-video watch time is counted.
-- ------------------------------------------------------------
WITH LiveVideos AS (
    SELECT  md.video_id
    FROM    ModerationDecision AS md
    JOIN    (SELECT video_id, MAX(decided_at) AS lt
             FROM   ModerationDecision
             GROUP  BY video_id) AS ld
            ON  ld.video_id = md.video_id AND ld.lt = md.decided_at
    WHERE   md.new_state = 'live'
),
DailyWatch AS (
    SELECT  v.owner_id                      AS creator_id,
            julianday(date(i.impressed_at)) AS day_jd,
            date(i.impressed_at)            AS day_date,
            SUM(vs.segment_end_ms - vs.segment_start_ms) AS watch_ms
    FROM    Video        AS v
    JOIN    LiveVideos   AS lv ON  lv.video_id = v.video_id
    JOIN    Impression   AS i  ON  i.video_id  = v.video_id
    JOIN    ViewSegment  AS vs ON  vs.impression_id = i.impression_id
    GROUP   BY v.owner_id, date(i.impressed_at)
),
Rolling AS (
    SELECT  creator_id,
            day_date,
            day_jd,
            SUM(watch_ms) OVER (
                PARTITION BY creator_id
                ORDER BY day_jd
                RANGE BETWEEN 6.0 PRECEDING AND CURRENT ROW
            ) AS rolling_7d_ms
    FROM    DailyWatch
),
Latest AS (
    SELECT  creator_id,
            MAX(day_date) AS latest_day,
            MAX(day_jd)   AS latest_jd
    FROM    Rolling
    GROUP   BY creator_id
)
SELECT  r.creator_id,
        r.rolling_7d_ms,
        prev.rolling_7d_ms                                          AS prev_week_ms,
        ROUND(
            (r.rolling_7d_ms - COALESCE(prev.rolling_7d_ms, 0)) * 1.0
            / NULLIF(COALESCE(prev.rolling_7d_ms, 0), 0) * 100,
        1)                                                           AS pct_change,
        RANK() OVER (ORDER BY r.rolling_7d_ms DESC)                 AS rnk
FROM    Rolling  AS r
JOIN    Latest   AS l    ON  l.creator_id = r.creator_id
                         AND l.latest_day = r.day_date
-- Self-join: find the rolling total for exactly 7 calendar days earlier.
-- NULL when the creator had no activity row on that exact date.
LEFT JOIN Rolling AS prev ON  prev.creator_id = r.creator_id
                          AND prev.day_jd     = r.day_jd - 7.0
ORDER   BY rnk
LIMIT   20;


-- ------------------------------------------------------------
-- F11 · Full nesting tree for a given agent session's tool calls,
--   with depth.
-- Uses a recursive CTE.  Base case: root calls (parent_call_id IS NULL)
--   in the chosen session.  Recursive case: children joined via
--   parent_call_id.  The path column gives a dot-separated ancestry
--   string useful for sorting and visual indentation.
-- Replace the session_id literal below with any session of interest.
-- ------------------------------------------------------------
WITH RECURSIVE CallTree AS (
    -- Base: root-level tool calls in the target session
    SELECT  tc.call_id,
            tc.parent_call_id,
            tc.tool_name,
            tc.turn_id,
            tc.errored,
            tc.latency_ms,
            1                           AS depth,
            CAST(tc.call_id AS TEXT)    AS path
    FROM    ToolCall AS tc
    JOIN    Turn     AS t ON t.turn_id = tc.turn_id
    WHERE   t.session_id = 1           -- substitute target session_id here
      AND   tc.parent_call_id IS NULL

    UNION ALL

    -- Recursive: children of already-found calls
    SELECT  tc.call_id,
            tc.parent_call_id,
            tc.tool_name,
            tc.turn_id,
            tc.errored,
            tc.latency_ms,
            ct.depth + 1,
            ct.path || '.' || CAST(tc.call_id AS TEXT)
    FROM    ToolCall AS tc
    JOIN    CallTree AS ct ON ct.call_id = tc.parent_call_id
)
SELECT  depth,
        call_id,
        parent_call_id,
        turn_id,
        tool_name,
        errored,
        latency_ms,
        path
FROM    CallTree
ORDER   BY path;


-- ------------------------------------------------------------
-- F12 · Sessions where the agent recommended a clip that the user
--   then watched to completion — reporting the clip's shelf position.
-- This is the critical link query: it traces the chain
--   Turn -> Recommendation -> Impression -> ViewSegment.
-- A recommendation "led to" an impression via the nullable FK
--   Impression.recommendation_id.  Completion is confirmed by
--   ViewSegment.completed = 1 on at least one segment of that impression.
-- If this query is hard to write, that is information about the schema:
--   the Recommendation -> Impression link must be present as a FK
--   for this join to be expressible at all.
-- ------------------------------------------------------------
SELECT  s.session_id,
        t.turn_id,
        r.video_id,
        r.shelf_position,
        COUNT(DISTINCT i.impression_id) AS completion_impressions
FROM    AgentSession   AS s
JOIN    Turn           AS t  ON  t.session_id        = s.session_id
JOIN    Recommendation AS r  ON  r.turn_id           = t.turn_id
JOIN    Impression     AS i  ON  i.recommendation_id = r.recommendation_id
JOIN    ViewSegment    AS vs ON  vs.impression_id     = i.impression_id
                             AND vs.completed         = 1
GROUP   BY s.session_id, t.turn_id, r.video_id, r.shelf_position
ORDER   BY s.session_id, t.turn_id, r.shelf_position;


-- ------------------------------------------------------------
-- F13 · Turns where the LLM judge scored above 4 but the user
--   gave a thumbs-down.
-- Comment on commercial value: this disagreement set is the most
--   commercially valuable data in the company because it reveals
--   the gap between automated quality measurement and actual user
--   satisfaction.  A turn scored highly on helpfulness, groundedness,
--   and safety by the judge model but rated negatively by the user
--   indicates a systematic blind spot in the judge's criteria — exactly
--   the signal needed to retrain or recalibrate the judge, to revise
--   the prompt template, or to discover that the agent is technically
--   correct but tonally or contextually wrong for this user population.
--   Rows in this set are training-data gold: every one is a labelled
--   example where the automated metric failed to predict the human outcome.
-- ------------------------------------------------------------
SELECT  t.turn_id,
        t.session_id,
        tqs.helpfulness,
        tqs.groundedness,
        tqs.safety,
        utr.rating,
        utr.rated_at
FROM    Turn             AS t
JOIN    TurnQualityScore AS tqs ON  tqs.turn_id = t.turn_id
JOIN    UserTurnRating   AS utr ON  utr.turn_id = t.turn_id
WHERE   (  COALESCE(tqs.helpfulness,  0) > 4.0
        OR COALESCE(tqs.groundedness, 0) > 4.0
        OR COALESCE(tqs.safety,       0) > 4.0)
  AND   utr.rating = 'down'
ORDER   BY t.turn_id;
--a thumbs-down from the user.  These disagreements highlight cases where
--the automated judge considered a response high-quality while the user
--did not, providing useful data for improving judge calibration,
--prompt templates, and the alignment between automated quality metrics
--and actual user satisfaction.

-- Assignment 2: join algorithms and predicate pushdown

-- J1
SELECT count(*) AS segments, sum(vs.segment_end_ms-vs.segment_start_ms) AS watch_ms
FROM ViewSegment vs JOIN Impression i ON i.impression_id=vs.impression_id;

-- J2
SELECT count(*) AS calls, sum(tc.latency_ms) AS latency_ms
FROM ToolCall tc JOIN Turn t ON t.turn_id=tc.turn_id;

-- J3
SELECT count(*) AS completed_segments
FROM Video v JOIN Impression i ON i.video_id=v.video_id
JOIN ViewSegment vs ON vs.impression_id=i.impression_id
WHERE v.owner_id=154384 AND vs.completed=1;

-- P_naive
SELECT joined.call_id, joined.turn_id, joined.session_id, joined.tool_name
FROM (SELECT tc.call_id,tc.turn_id,t.session_id,tc.tool_name
      FROM ToolCall tc JOIN Turn t ON t.turn_id=tc.turn_id
      WHERE tc.parent_call_id IS NULL) joined
WHERE joined.session_id=1 ORDER BY joined.call_id;

-- P_pushed
SELECT tc.call_id,tc.turn_id,t.session_id,tc.tool_name
FROM ToolCall tc JOIN (SELECT turn_id,session_id FROM Turn WHERE session_id=1) t
ON t.turn_id=tc.turn_id WHERE tc.parent_call_id IS NULL ORDER BY tc.call_id;
