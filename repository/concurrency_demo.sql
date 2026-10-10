-- Execute with: python3 concurrency_demo.py
-- Two connections are necessary; this is a coordinated schedule, not a
-- single-connection script. The driver executes these statements literally.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- T5.1 (A1 T2): A begins, appends ModerationDecision, B reads the last committed
-- decision, A commits, B reads the new decision in a NEW autocommit transaction.
-- Writer A:
-- BEGIN;
-- INSERT INTO ModerationDecision(video_id,new_state,actor_type,actor_id,decided_at)
-- VALUES(1,'taken_down','human',42,'2026-06-01T09:00:00Z');
-- Reader B: SELECT ... latest decision for video_id=1; -- sees old state
-- Writer A: COMMIT;
-- Reader B: SELECT ... latest decision for video_id=1; -- sees taken_down
-- B's two reads are separate transactions B1 and B2.
-- Conventional abstract-item conflict graph: A -> B1, A -> B2 (acyclic).
-- WAL committed-version dependency graph: B1 -> A -> B2 (also acyclic).
-- The report distinguishes conflict order from observed-version serial order.

-- T5.2/T5.3: two profile editors each append a suffix to the same display_name.
-- An application operation spans an autocommit read and a later write.
-- A: SELECT display_name FROM AppUser WHERE user_id=1; -- 'base'
-- B: SELECT display_name FROM AppUser WHERE user_id=1; -- 'base'
-- A: UPDATE AppUser SET display_name='base|A' WHERE user_id=1; COMMIT;
-- B: UPDATE AppUser SET display_name='base|B' WHERE user_id=1; COMMIT;
-- Outcome: base|B; A's edit is LOST. Graph A -> B (read/write, write/write)
-- and B -> A (read/write). The logical-operation schedule contains a cycle.
-- Individual SQLite autocommit transactions are still serializable: the bug
-- is the missing transaction boundary around each complete read/modify/write.

-- Prevention, for BOTH editors:
-- BEGIN IMMEDIATE;  -- before SELECT; reserve the sole SQLite writer
-- SELECT display_name FROM AppUser WHERE user_id=1;
-- UPDATE AppUser SET display_name=? WHERE user_id=1; -- fresh read + own suffix
-- COMMIT;
-- B attempts BEGIN IMMEDIATE while A owns the lock: SQLITE_BUSY with timeout=0.
-- Retry B's whole operation after A commits; final value base|A|B.
-- Cost: B waits or retries for the database-wide writer reservation.
-- Retrying the whole operation re-reads the latest value; readers still proceed.
