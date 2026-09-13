-- ============================================================
-- ScrollSense  transactions.sql
-- Deliverable G.3 — Three transaction demonstrations
-- SQLite 3.44+  |  Run AFTER schema.sql, views.sql, generate_data.py
--
-- T1 is fully executable as a single-connection SQL script.
-- T2 and T3 require two simultaneous database connections and
--   cannot be driven by a single SQL script.  Both are therefore
--   presented as annotated SQL blocks showing exactly which
--   statement each connection executes and in what order,
--   followed by the captured output that proves the expected
--   behaviour.  The same statements are executed live in
--   transactions.py, which opens two concurrent sqlite3
--   connections and records the results.
-- ============================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ============================================================
-- T1 · Like retraction must be atomic.
-- Failure mode (§2.7): if the process dies after inserting the
--   LikeRetraction row but before the transaction commits, an
--   orphan retraction exists with no committed like state, or
--   the retraction is lost entirely.
-- The Like row is never deleted (Assumption 10); only a separate
--   LikeRetraction row is written.
-- ============================================================

-- ── Setup ────────────────────────────────────────────────────
INSERT OR IGNORE INTO Like (like_id, user_id, video_id, liked_at)
VALUES (999999, 1, 1, '2026-01-15T10:00:00Z');

-- ── State before ─────────────────────────────────────────────
SELECT 'BEFORE T1 — Like exists:'       AS label, COUNT(*) AS cnt
FROM   Like           WHERE like_id = 999999;
SELECT 'BEFORE T1 — Retraction exists:' AS label, COUNT(*) AS cnt
FROM   LikeRetraction WHERE like_id = 999999;
-- Expected output:
--   BEFORE T1 — Like exists:       | 1
--   BEFORE T1 — Retraction exists: | 0

-- ── Failing transaction (deliberate failure injected) ─────────
-- The failure is a duplicate INSERT for the same like_id, which
-- violates UNIQUE on LikeRetraction.like_id and raises
-- SQLITE_CONSTRAINT_UNIQUE.  This simulates a process kill or
-- connection drop mid-operation.  SQLite does not auto-rollback
-- inside an explicit BEGIN/COMMIT block; ROLLBACK is explicit.
BEGIN;
    INSERT INTO LikeRetraction (like_id, retracted_at)
    VALUES (999999, '2026-01-15T10:00:45Z');

    INSERT INTO LikeRetraction (like_id, retracted_at)
    VALUES (999999, '2026-01-15T10:00:46Z');  -- UNIQUE violation → SQLITE_CONSTRAINT_UNIQUE
ROLLBACK;
-- Both inserts are undone; the Like row is unaffected.

-- ── Consistency proof after failed transaction ────────────────
SELECT 'AFTER T1 (failed) — Like still exists:' AS label, COUNT(*) AS cnt
FROM   Like           WHERE like_id = 999999;
SELECT 'AFTER T1 (failed) — Retraction absent:' AS label, COUNT(*) AS cnt
FROM   LikeRetraction WHERE like_id = 999999;
-- Expected output:
--   AFTER T1 (failed) — Like still exists: | 1
--   AFTER T1 (failed) — Retraction absent: | 0

-- ── Successful transaction ────────────────────────────────────
BEGIN;
    INSERT INTO LikeRetraction (like_id, retracted_at)
    VALUES (999999, '2026-01-15T10:00:45Z');
COMMIT;

SELECT 'AFTER T1 (success) — Retraction present:' AS label, COUNT(*) AS cnt
FROM   LikeRetraction WHERE like_id = 999999;
SELECT 'AFTER T1 (success) — Like still present:' AS label, COUNT(*) AS cnt
FROM   Like           WHERE like_id = 999999;
-- Expected output:
--   AFTER T1 (success) — Retraction present: | 1
--   AFTER T1 (success) — Like still present: | 1

-- ── Cleanup ───────────────────────────────────────────────────
DELETE FROM LikeRetraction WHERE like_id = 999999;
DELETE FROM Like           WHERE like_id = 999999;


-- ============================================================
-- T2 · Moderation decision — WAL read isolation.
-- Failure mode eliminated: the founders required two writes
--   (INSERT ModerationDecision + UPDATE Video.current_state);
--   one could land without the other.  This design has ONE write
--   per moderation event; current state is always derived from
--   the latest ModerationDecision row, so there is no dual-write
--   anomaly possible.
--
-- Demonstration: WAL mode allows a reader (Connection B) to see
--   the last committed snapshot while a writer (Connection A)
--   holds an open transaction, without blocking.
--
-- Two-connection execution order (run live in transactions.py):
-- ============================================================

-- ── Connection A ─────────────────────────────────────────────
-- BEGIN;
-- INSERT INTO ModerationDecision
--        (video_id, new_state, actor_type, actor_id, decided_at)
-- VALUES (1, 'taken_down', 'human', 42, '2026-06-01T09:00:00Z');
-- -- (leave uncommitted)

-- ── Connection B (concurrent, not blocked in WAL mode) ───────
-- SELECT current_state
-- FROM   v_video_current_state
-- WHERE  video_id = 1;
-- Expected: 'live'   ← committed snapshot; A's write not yet visible

-- ── Connection A commits ──────────────────────────────────────
-- COMMIT;

-- ── Connection B queries again ────────────────────────────────
-- SELECT current_state
-- FROM   v_video_current_state
-- WHERE  video_id = 1;
-- Expected: 'taken_down'   ← now visible after commit

-- ── Captured output (from transactions.py) ───────────────────
-- Connection A: inserted 'taken_down' (NOT committed)
-- Connection B (before commit): current_state = live
-- Connection A: COMMITTED
-- Connection B (after commit):  current_state = taken_down
--
-- In the default rollback-journal mode, Connection B would be
-- BLOCKED rather than shown the old value.  WAL mode is required
-- to demonstrate isolation rather than locking.


-- ============================================================
-- T3 · Handle change: twice-a-year limit + SQLITE_BUSY.
-- Part 1 (single connection): the application-level twice-a-year
--   check rejects the third attempt within one calendar year.
-- Part 2 (two connections): SQLITE_BUSY when a second connection
--   tries to write while another holds the write lock.
-- ============================================================

-- ── Setup ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS HandleChangeLog (
    change_id  INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES AppUser(user_id) ON DELETE CASCADE,
    old_handle TEXT    NOT NULL,
    new_handle TEXT    NOT NULL,
    changed_at TEXT    NOT NULL   -- ISO-8601
);

DROP VIEW IF EXISTS v_handle_changes_this_year;
CREATE VIEW v_handle_changes_this_year AS
SELECT  user_id,
        COUNT(*) AS changes_this_year
FROM    HandleChangeLog
WHERE   strftime('%Y', changed_at) = strftime('%Y', 'now')
GROUP   BY user_id;

-- ── Change 1 (succeeds) ──────────────────────────────────────
BEGIN;
    INSERT INTO HandleChangeLog (user_id, old_handle, new_handle, changed_at)
    VALUES (1, 'user_3207035', 'cool_handle_v1', '2026-03-01T10:00:00Z');
    UPDATE AppUser SET handle = 'cool_handle_v1' WHERE user_id = 1;
COMMIT;

SELECT 'T3 — After change 1, changes this year:' AS label,
       COALESCE(changes_this_year, 0) AS n
FROM   v_handle_changes_this_year WHERE user_id = 1;
-- Expected: n = 1

-- ── Change 2 (succeeds) ──────────────────────────────────────
BEGIN;
    INSERT INTO HandleChangeLog (user_id, old_handle, new_handle, changed_at)
    VALUES (1, 'cool_handle_v1', 'cool_handle_v2', '2026-07-15T14:00:00Z');
    UPDATE AppUser SET handle = 'cool_handle_v2' WHERE user_id = 1;
COMMIT;

SELECT 'T3 — After change 2, changes this year:' AS label,
       COALESCE(changes_this_year, 0) AS n
FROM   v_handle_changes_this_year WHERE user_id = 1;
-- Expected: n = 2

-- ── Change 3: application pre-flight check rejects it ────────
-- The twice-a-year limit is NOT a database constraint (E.2,
-- Assumption 2); it is enforced by application code that checks
-- the count BEFORE opening a transaction.  The SELECT bel
-- simulates that pre-flight check.  If changes_this_year >= 2
-- the application never opens a transaction; no database error
-- is raised.
SELECT  CASE
            WHEN COALESCE(changes_this_year, 0) >= 2
            THEN 'T3 — Change 3 REJECTED: twice-a-year limit reached'
            ELSE 'T3 — Change 3 allowed (unexpected)'
        END AS application_check_result
FROM    (SELECT COALESCE(
            (SELECT changes_this_year FROM v_handle_changes_this_year
             WHERE user_id = 1), 0) AS changes_this_year);
-- Expected output:
--   T3 — Change 3 REJECTED: twice-a-year limit reached

-- ── Cleanup ───────────────────────────────────────────────────
UPDATE AppUser SET handle = 'user_3207035' WHERE user_id = 1;
DELETE FROM HandleChangeLog WHERE user_id = 1;

-- ── Part 2: SQLITE_BUSY (two connections, run in transactions.py)
-- Connection A holds an open write transaction.
-- Connection B attempts BEGIN IMMEDIATE (requires the write lock).
-- SQLite raises SQLITE_BUSY because only one writer is permitted.
--
-- Two-connection execution order:
-- ── Connection A ─────────────────────────────────────────────
-- BEGIN IMMEDIATE;
-- INSERT INTO HandleChangeLog (user_id,old_handle,new_handle,changed_at)
-- VALUES (2,'h_old','h_new','2026-04-01T12:00:00Z');
-- -- (leave uncommitted)

-- ── Connection B ─────────────────────────────────────────────
-- BEGIN IMMEDIATE;
-- Expected: raises SQLITE_BUSY — 'database is locked'

-- ── Connection A ─────────────────────────────────────────────
-- ROLLBACK;

-- ── Captured output (from transactions.py) ───────────────────
-- Connection A: BEGIN IMMEDIATE + INSERT (write lock held)
-- Connection B: database is locked
-- Connection A: ROLLBACK
-- SQLITE_BUSY caught: True
--
-- SQLite permits exactly one writer at a time, sidestepping the
-- lost-update anomaly without row-level locking or MVCC.
-- A multi-writer engine (PostgreSQL) must solve this explicitly;
-- SQLite serialises all writes at the database level instead.