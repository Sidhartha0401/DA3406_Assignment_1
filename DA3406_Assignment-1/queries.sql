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
WHERE   i.impressed_at >= datetime(
            (SELECT MAX(impressed_at) FROM Impression), '-7 days')
GROUP   BY at.track_id
ORDER   BY distinct_videos DESC
LIMIT   10;
-- Rows returned: 10   Runtime: 0.115s
-- Reading: Top tracks reach 8--9 distinct videos; the distribution is flat, consistent with a small pool of equally popular audio.


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
-- Rows returned: 714 (= number of creators)   Runtime: 0.21s
-- Reading: 714 rows returned (= number of creators); the LEFT JOIN correctly preserves creators with no live-clip views at zero watch hours, confirming no silent drops.


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
-- Rows returned: 6171   Runtime: 0.005s

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
-- Rows returned: 6171  Runtime: 0.004s


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
-- Rows returned: 616   Runtime: ~0s
-- Reading: All 616 results fall within 0--60 seconds; the explicit lower bound of 0 excludes any retraction timestamped before its like.


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
-- Rows returned: 1501   Runtime: ~0.025s
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
-- Rows returned: 27   Runtime: ~0.12s
-- Reading: 525 users were exposed to creator 461's content but
--   produced zero explicit signals — the typical silent majority
--   of a short-video feed.

-- UNION vs UNION ALL on the same signal roll-up:
SELECT user_id
FROM   Like  AS l JOIN Video AS v ON v.video_id = l.video_id WHERE v.owner_id = 461
UNION
SELECT user_id
FROM   Share AS s JOIN Video AS v ON v.video_id = s.video_id WHERE v.owner_id = 461;
-- Rows returned: 27
-- UNION deduplicates: a user who both liked and shared one of
--   creator 461's clips appears only once.

SELECT user_id
FROM   Like  AS l JOIN Video AS v ON v.video_id = l.video_id WHERE v.owner_id = 461
UNION ALL
SELECT user_id
FROM   Share AS s JOIN Video AS v ON v.video_id = s.video_id WHERE v.owner_id = 461;
-- Rows returned: 27
-- UNION ALL preserves duplicates: that user appears twice.
-- Difference = 0:
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
-- Rows returned: 1396   Runtime: ~0.62s
-- Reading:  1,396 session--template combinations exceeded the threshold; session 185 (search_shelf} v4) is the costliest at $18.45, computed against historically frozen rates.


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
-- Rows returned: 1636   Runtime: ~0.02s
-- Reading: 1,636 videos have more than two decisions; all five shown follow {pending to live to {demoted|taken_down|age_restricted\}}, confirming the event log preserves chronological order.


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
ORDER   BY longest_streak_days DESC
LIMIT   20;
-- Rows returned: 20 (top 20 shown; query covers all users)
-- Runtime: ~0.755s
-- Reading: User 2389 leads with an 18-day streak; top-5 users range from 12--18 consecutive active days.


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
-- Rows returned: 20 (top 20 by most-recent rolling 7-day total)
-- Runtime: ~1.003 s
-- Reading: Creator 3992 leads with 367 s rolling watch time; {NULL} in {prev\_week\_ms} correctly indicates no activity row exactly 7 calendar days prior (sparse creator history).


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
-- Rows returned: 9 (for session_id = 1)   Runtime: ~0.017s
-- Reading: Session 1 yields 9 calls; call 2 (path {1.2}) is the only nested child, confirming the recursive CTE correctly reconstructs depth from {parent\_call\_id}.


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
-- Rows returned: 59   Runtime: ~0.074s
-- Reading: 59 recommendation-to-completion links found; completed views occur across multiple shelf positions, not only position 1.


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
-- Rows returned: 43   Runtime: ~0.032s
-- Reading: 43 turns had at least one LLM judge dimension above 4.0 but received
--a thumbs-down from the user.  These disagreements highlight cases where
--the automated judge considered a response high-quality while the user
--did not, providing useful data for improving judge calibration,
--prompt templates, and the alignment between automated quality metrics
--and actual user satisfaction.