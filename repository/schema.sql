-- ============================================================
-- ScrollSense  schema.sql
-- SQLite 3.44+
-- Run:  sqlite3 scrollsense.db < schema.sql
-- ============================================================

PRAGMA foreign_keys  = ON;
PRAGMA journal_mode  = WAL;

-- ============================================================
-- LOOKUP TABLES FOR EXTENSIBLE VALUE SETS
-- Used for value sets that Trust & Safety or Finance may extend.
-- A CHECK(col IN (...)) is cheap but invisible to queries and
-- hard to extend; a lookup table with a FK is queryable and
-- extensible by INSERT without a schema migration.
-- ============================================================

CREATE TABLE ModerationState (
    state   TEXT PRIMARY KEY
) STRICT;

INSERT INTO ModerationState VALUES
    ('pending'),('live'),('age_restricted'),('demoted'),('taken_down');

CREATE TABLE MonetisationTier (
    tier    TEXT PRIMARY KEY
) STRICT;

INSERT INTO MonetisationTier VALUES
    ('emerging'),('rising'),('established'),('top');

-- ============================================================
-- TYPE-AFFINITY DEMONSTRATION  (E.1 requirement)
-- SQLite maps declared type names to one of five storage classes
-- (NULL, INTEGER, REAL, TEXT, BLOB) by a substring rule.
-- The test below inserts a TEXT value into an INTEGER-affinity
-- column.  SQLite silently stores the text; it does NOT error.
-- This means domain correctness should rely on explicit constraints
-- such as CHECK, NOT NULL, UNIQUE, and FOREIGN KEY rather than
-- on type declarations alone.
-- ============================================================

CREATE TABLE _type_affinity_test (
    id      INTEGER PRIMARY KEY,
    val     INTEGER
);
INSERT INTO _type_affinity_test VALUES (1, 'hello');
-- SELECT typeof(val) FROM _type_affinity_test WHERE id = 1;
-- Returns 'text', not 'integer'.
-- Consequence: every domain constraint in this schema is enforced
-- by CHECK, not by the type declaration.  Type names are hints;
-- CHECK constraints are the actual enforcement.

-- ============================================================
-- §2.1  USERS
-- ============================================================

CREATE TABLE AppUser (
    user_id      INTEGER PRIMARY KEY,
    handle       TEXT    NOT NULL,          -- stored as typed by user; uniqueness via index below
    display_name TEXT    NOT NULL,
    auth_type    TEXT    NOT NULL CHECK (auth_type IN ('phone','google')),
    auth_value   TEXT    NOT NULL UNIQUE,   -- phone number or Google identifier
    created_at   TEXT    NOT NULL           -- ISO-8601 datetime; chosen for readability and
                                            -- direct TEXT comparison in F3/F9/F10
);

-- Handle uniqueness: case-insensitive, active accounts only.
-- COLLATE NOCASE enforces ASCII case folding.
-- NOTE: NOCASE folds only ASCII (U+0000–U+007F).  A handle written
-- in Tamil or other non-ASCII scripts is NOT covered; two Tamil
-- handles differing only in Unicode case would be treated as distinct.
-- The "active accounts only" half cannot be expressed with a plain
-- UNIQUE constraint; it is enforced in application code at the point
-- of handle assignment and change.
CREATE UNIQUE INDEX ux_handle_nocase
    ON AppUser(handle COLLATE NOCASE);
-- This enforces global case-insensitive uniqueness, not just among
-- active accounts.  The active-only rule is application-enforced.

CREATE TABLE InterestCategory (
    category_id  INTEGER PRIMARY KEY,
    name         TEXT    NOT NULL UNIQUE
);

CREATE TABLE DeclaredInterest (
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    category_id  INTEGER NOT NULL REFERENCES InterestCategory(category_id)
                         ON DELETE CASCADE,
    PRIMARY KEY (user_id, category_id)
);

CREATE TABLE InferredInterest (
    inference_id INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    category_id  INTEGER NOT NULL REFERENCES InterestCategory(category_id)
                         ON DELETE CASCADE,
    confidence   REAL    NOT NULL CHECK (confidence BETWEEN 0.0 AND 1.0),
    week_start   TEXT    NOT NULL,          -- ISO-8601 date of Monday of inference week
    suppressed   INTEGER NOT NULL DEFAULT 0 CHECK (suppressed IN (0,1)),
                                            -- 0 = not suppressed; 1 = user suppressed this inference
    UNIQUE (user_id, category_id, week_start)
                                            -- candidate key from D.1: ML pipeline runs once per week
                                            -- per user per category
);

CREATE TABLE AccountStatusPeriod (
    status_period_id INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES AppUser(user_id)
                             ON DELETE CASCADE,
    status           TEXT    NOT NULL CHECK (status IN ('active','deactivated','pending_deletion')),
    valid_from       TEXT    NOT NULL,      -- ISO-8601 datetime
    valid_to         TEXT                   -- NULL = account currently in this status
);

-- ============================================================
-- §2.2  CREATORS AND CONTENT
-- ============================================================

CREATE TABLE CreatorPeriod (
    creator_period_id INTEGER PRIMARY KEY,
    user_id           INTEGER NOT NULL REFERENCES AppUser(user_id)
                              ON DELETE CASCADE,
    valid_from        TEXT    NOT NULL,     -- ISO-8601 datetime
    valid_to          TEXT                  -- NULL = currently a creator
);

CREATE TABLE CreatorTierPeriod (
    tier_period_id    INTEGER PRIMARY KEY,
    creator_period_id INTEGER NOT NULL REFERENCES CreatorPeriod(creator_period_id)
                              ON DELETE CASCADE,
    tier              TEXT    NOT NULL REFERENCES MonetisationTier(tier),
                              -- FK to lookup table; extensible by INSERT without schema change
    valid_from        TEXT    NOT NULL,     -- ISO-8601 datetime
    valid_to          TEXT                  -- NULL = current tier
);

-- AudioTrack and Video reference each other (original_video_id on AudioTrack
-- references Video; audio_track_id on Video references AudioTrack).
-- Both FKs are DEFERRABLE INITIALLY DEFERRED so that both rows can be
-- inserted in the same transaction before either FK is checked.

CREATE TABLE AudioTrack (
    track_id          INTEGER PRIMARY KEY,
    track_type        TEXT    NOT NULL CHECK (track_type IN ('original','licensed')),
    original_video_id INTEGER             -- NULL = licensed track with no originating video
                              REFERENCES Video(video_id)
                              ON DELETE SET NULL          -- track survives if its origin video is deleted;
                              DEFERRABLE INITIALLY DEFERRED
                              -- 50,000 other clips may reference this track
);

CREATE TABLE Video (
    video_id       INTEGER PRIMARY KEY,
    owner_id       INTEGER NOT NULL REFERENCES AppUser(user_id)
                           ON DELETE RESTRICT,
                           -- RESTRICT: do not silently delete a user's videos;
                           -- deactivation is the correct path
    audio_track_id INTEGER             -- NULL = this video has no audio track
                           REFERENCES AudioTrack(track_id)
                           ON DELETE SET NULL              -- video survives if its track is deleted
                           DEFERRABLE INITIALLY DEFERRED,
    duration_ms    INTEGER NOT NULL CHECK (duration_ms BETWEEN 20000 AND 90000),
    caption        TEXT,               -- NULL = no caption provided
    uploaded_at    TEXT    NOT NULL    -- ISO-8601 datetime
    -- NOTE: no current_moderation_state column.
    -- Current state is derived from ModerationDecision (latest row per video).
    -- This eliminates the dual-write anomaly described in §2.7.
);

CREATE TABLE Hashtag (
    hashtag_id   INTEGER PRIMARY KEY,
    tag          TEXT    NOT NULL UNIQUE   -- stored lower-cased and trimmed at ingestion
);

CREATE TABLE VideoHashtag (
    video_id     INTEGER NOT NULL REFERENCES Video(video_id)
                         ON DELETE CASCADE,
    hashtag_id   INTEGER NOT NULL REFERENCES Hashtag(hashtag_id)
                         ON DELETE CASCADE,
    PRIMARY KEY (video_id, hashtag_id)
);

CREATE TABLE ModerationDecision (
    decision_id  INTEGER PRIMARY KEY,
    video_id     INTEGER NOT NULL REFERENCES Video(video_id)
                         ON DELETE CASCADE,
    new_state    TEXT    NOT NULL REFERENCES ModerationState(state),
                         -- FK to lookup table; T&S can add states by INSERT
    actor_type   TEXT    NOT NULL CHECK (actor_type IN ('classifier','human')),
    actor_id     INTEGER,                  -- NULL = automated classifier (no human actor ID)
    decided_at   TEXT    NOT NULL          -- ISO-8601 datetime
);

-- Index to support v_video_current_state view (one lookup per video)
CREATE INDEX ix_moderation_video_time
    ON ModerationDecision(video_id, decided_at DESC);

-- ============================================================
-- §2.3  SOCIAL GRAPH
-- ============================================================

CREATE TABLE Follow (
    follow_id    INTEGER PRIMARY KEY,
    follower_id  INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
                         -- CASCADE: if an account is hard-deleted, its social-graph rows
                         -- are removed with it. Assumption 7 (ended_at on block) concerns
                         -- live accounts; it does not apply to hard account deletion.
                         -- Historical follower counts query AccountStatusPeriod + active
                         -- Follow rows; a fully deleted user leaves neither.
    followee_id  INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    started_at   TEXT    NOT NULL,
    ended_at     TEXT                      -- NULL = currently active; set by block (not deleted)
);

CREATE TABLE Block (
    block_id     INTEGER PRIMARY KEY,
    blocker_id   INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    blocked_id   INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    blocked_at   TEXT    NOT NULL          -- ISO-8601 datetime
);

CREATE TABLE Mute (
    mute_id      INTEGER PRIMARY KEY,
    muter_id     INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    muted_id     INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    started_at   TEXT    NOT NULL,         -- ISO-8601 datetime
    ended_at     TEXT                      -- NULL = mute currently active
);

-- ============================================================
-- §2.4  WATCH TELEMETRY
-- ============================================================

-- Impression and Recommendation reference each other:
-- Impression.recommendation_id → Recommendation (optional)
-- Recommendation is created first (at turn time) so the FK on
-- Impression pointing back is the correct direction.
-- DEFERRABLE allows both to be loaded in one transaction.

CREATE TABLE Impression (
    impression_id     INTEGER PRIMARY KEY,
    user_id           INTEGER NOT NULL REFERENCES AppUser(user_id)
                              ON DELETE CASCADE,
    video_id          INTEGER NOT NULL REFERENCES Video(video_id)
                              ON DELETE CASCADE,
    recommendation_id INTEGER             -- NULL = organic feed ranking, not from agent
                              REFERENCES Recommendation(recommendation_id)
                              ON DELETE SET NULL          -- impression survives if recommendation deleted
                              DEFERRABLE INITIALLY DEFERRED,
    feed_position     INTEGER NOT NULL CHECK (feed_position >= 1),
                              -- position at moment of impression; fixed at impression time (Assumption 9)
    model_version     TEXT    NOT NULL,   -- ranking model version that placed this clip
    impressed_at      TEXT    NOT NULL    -- ISO-8601 datetime
);

CREATE TABLE ViewSegment (
    impression_id    INTEGER NOT NULL REFERENCES Impression(impression_id)
                             ON DELETE CASCADE,
    segment_start_ms INTEGER NOT NULL CHECK (segment_start_ms >= 0),
    segment_end_ms   INTEGER NOT NULL CHECK (segment_end_ms > segment_start_ms),
    completed        INTEGER NOT NULL CHECK (completed IN (0,1)),
                             -- 1 = end of clip was reached during this segment
    PRIMARY KEY (impression_id, segment_start_ms)
    -- Weak entity: composite PK includes the parent FK.
    -- Watch time per impression = SUM(segment_end_ms - segment_start_ms).
    -- Completion per impression  = MAX(completed) across segments.
);

CREATE TABLE Like (
    like_id      INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    video_id     INTEGER NOT NULL REFERENCES Video(video_id)
                         ON DELETE CASCADE,
    liked_at     TEXT    NOT NULL          -- ISO-8601 datetime
);

CREATE TABLE LikeRetraction (
    retraction_id INTEGER PRIMARY KEY,
    like_id       INTEGER NOT NULL UNIQUE  -- one retraction per like; UNIQUE enforces 1:0..1
                          REFERENCES Like(like_id)
                          ON DELETE CASCADE,
    retracted_at  TEXT    NOT NULL         -- ISO-8601 datetime
);

CREATE TABLE ExplicitSignal (
    signal_id    INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    video_id     INTEGER NOT NULL REFERENCES Video(video_id)
                         ON DELETE CASCADE,
    signal_type  TEXT    NOT NULL CHECK (
                     signal_type IN ('save','comment','follow_from_feed',
                                     'not_interested','report')
                 ),
    occurred_at  TEXT    NOT NULL          -- ISO-8601 datetime
);

CREATE TABLE Share (
    share_id     INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    video_id     INTEGER NOT NULL REFERENCES Video(video_id)
                         ON DELETE CASCADE,
    destination  TEXT    NOT NULL CHECK (
                     destination IN ('whatsapp','instagram','copied_link')
                 ),
    shared_at    TEXT    NOT NULL          -- ISO-8601 datetime
);

-- ============================================================
-- §2.5  AGENT LAYER
-- ============================================================

CREATE TABLE AgentSession (
    session_id   INTEGER PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES AppUser(user_id)
                         ON DELETE CASCADE,
    started_at   TEXT    NOT NULL          -- ISO-8601 datetime
);

CREATE TABLE PromptTemplate (
    template_id   INTEGER PRIMARY KEY,
    template_name TEXT    NOT NULL,
    version       INTEGER NOT NULL CHECK (version >= 1),
    template_text TEXT    NOT NULL,        -- exact text at this version; never updated after insert
    created_at    TEXT    NOT NULL,        -- ISO-8601 datetime
    UNIQUE (template_name, version)
);

CREATE TABLE ModelPricing (
    pricing_id        INTEGER PRIMARY KEY,
    model_name        TEXT    NOT NULL,
    vendor            TEXT    NOT NULL,
    input_rate        REAL    NOT NULL CHECK (input_rate >= 0),
    output_rate       REAL    NOT NULL CHECK (output_rate >= 0),
    cached_input_rate REAL    NOT NULL CHECK (cached_input_rate >= 0),
    valid_from        TEXT    NOT NULL,    -- ISO-8601 datetime
    valid_to          TEXT,               -- NULL = currently in effect
    UNIQUE (model_name, vendor, valid_from)
);

CREATE TABLE Turn (
    turn_id           INTEGER PRIMARY KEY,
    session_id        INTEGER NOT NULL REFERENCES AgentSession(session_id)
                              ON DELETE CASCADE,
    template_id       INTEGER NOT NULL REFERENCES PromptTemplate(template_id)
                              ON DELETE RESTRICT,
                              -- RESTRICT: never delete a template that has turns;
                              -- historical turns must stay linked to exact template text
    pricing_id        INTEGER NOT NULL REFERENCES ModelPricing(pricing_id)
                              ON DELETE RESTRICT,
                              -- RESTRICT: never delete a pricing row that has turns;
                              -- historical cost must never be altered
    turn_order        INTEGER NOT NULL CHECK (turn_order >= 1),
    user_message      TEXT    NOT NULL,
    assistant_message TEXT    NOT NULL,
    model_name        TEXT    NOT NULL,
    temperature       REAL    CHECK (temperature BETWEEN 0.0 AND 2.0),
                                           -- NULL = model used its default temperature
    input_tokens      INTEGER NOT NULL CHECK (input_tokens  >= 0),
    output_tokens     INTEGER NOT NULL CHECK (output_tokens >= 0),
    cached_tokens     INTEGER NOT NULL CHECK (cached_tokens >= 0),
    responded_at      TEXT    NOT NULL,    -- ISO-8601 datetime
    UNIQUE (session_id, turn_order)
);

CREATE TABLE ToolCall (
    call_id        INTEGER PRIMARY KEY,
    turn_id        INTEGER NOT NULL REFERENCES Turn(turn_id)
                           ON DELETE CASCADE,
    parent_call_id INTEGER             -- NULL = root-level call with no parent
                           REFERENCES ToolCall(call_id)
                           ON DELETE SET NULL          -- child survives if parent deleted;
                                                       -- do not cascade-delete whole subtree
                           DEFERRABLE INITIALLY DEFERRED,
    tool_name      TEXT    NOT NULL,
    arguments      TEXT    CHECK (arguments IS NULL OR json_valid(arguments)),
                           -- JSON text; shape varies per tool (see E.4 justification)
                           -- NULL only if the tool takes no arguments
    result         TEXT    ,
                           -- NULL = call errored and returned no result
    latency_ms     INTEGER CHECK (latency_ms >= 0),
    errored        INTEGER NOT NULL CHECK (errored IN (0,1)),
    called_at      TEXT    NOT NULL        -- ISO-8601 datetime
);

CREATE TABLE Recommendation (
    recommendation_id INTEGER PRIMARY KEY,
    turn_id           INTEGER NOT NULL REFERENCES Turn(turn_id)
                              ON DELETE CASCADE,
    video_id          INTEGER NOT NULL REFERENCES Video(video_id)
                              ON DELETE RESTRICT,
                              -- RESTRICT: do not silently delete agent recommendations
                              -- when a video is removed; T&S needs audit trail
    shelf_position    INTEGER NOT NULL CHECK (shelf_position >= 1)
);

CREATE TABLE TurnQualityScore (
    score_id     INTEGER PRIMARY KEY,
    turn_id      INTEGER NOT NULL REFERENCES Turn(turn_id)
                         ON DELETE CASCADE,
    helpfulness  REAL    CHECK (helpfulness  BETWEEN 0.0 AND 5.0),
                                            -- NULL = dimension not scored
    groundedness REAL    CHECK (groundedness BETWEEN 0.0 AND 5.0),
    safety       REAL    CHECK (safety       BETWEEN 0.0 AND 5.0),
    judge_model  TEXT    NOT NULL,
    scored_at    TEXT    NOT NULL           -- ISO-8601 datetime
);

CREATE TABLE UserTurnRating (
    rating_id    INTEGER PRIMARY KEY,
    turn_id      INTEGER NOT NULL REFERENCES Turn(turn_id)
                         ON DELETE CASCADE,
    rating       TEXT    NOT NULL CHECK (rating IN ('up','down')),
    rated_at     TEXT    NOT NULL           -- ISO-8601 datetime
);