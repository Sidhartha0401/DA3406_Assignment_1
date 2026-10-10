"""Execute real, event-coordinated two-connection schedules on an isolated fixture."""
import argparse
from contextlib import closing
import json
import sqlite3
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def run(output):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    events = []
    event_lock = threading.Lock()
    origin = time.perf_counter()

    def log(actor, action, value=None):
        with event_lock:
            events.append(dict(seconds=time.perf_counter()-origin,
                               actor=actor, action=action, value=value))

    with tempfile.TemporaryDirectory(prefix="a2-concurrency-", dir=output.parent) as tmp:
        db = Path(tmp)/"fixture.db"

        def connect():
            c = sqlite3.connect(db, timeout=0, isolation_level=None)
            c.execute("PRAGMA foreign_keys=ON")
            return c

        a = connect()
        a.executescript((ROOT/"schema.sql").read_text())
        a.executescript((ROOT/"views.sql").read_text())
        a.execute("INSERT INTO AppUser VALUES(1,'fixture','base','google','fixture@example.invalid','2025-01-01T00:00:00Z')")
        a.execute("INSERT INTO Video VALUES(1,1,NULL,20000,'fixture','2025-01-01T00:00:00Z')")
        a.execute("INSERT INTO ModerationDecision VALUES(1,1,'live','classifier',NULL,'2025-01-02T00:00:00Z')")
        b = connect()
        state_sql = "SELECT current_state FROM v_video_current_state WHERE video_id=1"
        # A1 T2: independent B autocommit reads on either side of A's commit.
        a.execute("BEGIN")
        a.execute("INSERT INTO ModerationDecision(video_id,new_state,actor_type,actor_id,decided_at) VALUES(1,'taken_down','human',42,'2026-06-01T09:00:00Z')")
        log("A", "BEGIN; append uncommitted moderation decision", "taken_down")
        old = b.execute(state_sql).fetchone()[0]
        log("B1", "autocommit read while A write is uncommitted", old)
        a.execute("COMMIT")
        log("A", "COMMIT moderation decision")
        new = b.execute(state_sql).fetchone()[0]
        log("B2", "new autocommit read after A commit", new)
        assert (old, new) == ("live", "taken_down")

        # Retraction rollback after a real UNIQUE-constraint failure.
        a.execute("INSERT INTO Like VALUES(1,1,1,'2025-01-02T00:00:00Z')")
        a.execute("BEGIN")
        try:
            a.execute("INSERT INTO LikeRetraction(like_id,retracted_at) VALUES(1,'2025-01-02T00:00:01Z')")
            a.execute("INSERT INTO LikeRetraction(like_id,retracted_at) VALUES(1,'2025-01-02T00:00:02Z')")
            raise AssertionError("failure injection did not fail")
        except sqlite3.IntegrityError as exc:
            a.execute("ROLLBACK")
            log("T1", "duplicate retraction failure and ROLLBACK", str(exc))
        assert a.execute("SELECT count(*) FROM LikeRetraction").fetchone()[0] == 0
        assert a.execute("SELECT count(*) FROM Like").fetchone()[0] == 1

        # Twice-a-year guard: decision and update in the same reserved transaction.
        a.execute("CREATE TABLE HandleChangeLog(change_id INTEGER PRIMARY KEY,user_id INTEGER NOT NULL REFERENCES AppUser(user_id),old_handle TEXT,new_handle TEXT,changed_at TEXT)")
        handle_outcomes = []
        for i in range(3):
            a.execute("BEGIN IMMEDIATE")
            count = a.execute("SELECT count(*) FROM HandleChangeLog WHERE user_id=1 AND changed_at>='2026-01-01' AND changed_at<'2027-01-01'").fetchone()[0]
            if count >= 2:
                a.execute("ROLLBACK")
                handle_outcomes.append("rejected")
                log("T3", "third handle change rejected atomically", count)
            else:
                old_handle = a.execute("SELECT handle FROM AppUser WHERE user_id=1").fetchone()[0]
                a.execute("INSERT INTO HandleChangeLog(user_id,old_handle,new_handle,changed_at) VALUES(1,?,?,?)", (old_handle, f"fixture{i}", f"2026-0{i+1}-01T00:00:00Z"))
                a.execute("UPDATE AppUser SET handle=? WHERE user_id=1", (f"fixture{i}",))
                a.execute("COMMIT")
                handle_outcomes.append("accepted")
        assert handle_outcomes == ["accepted", "accepted", "rejected"]
        a.close()
        b.close()

        def name(c):
            return c.execute("SELECT display_name FROM AppUser WHERE user_id=1").fetchone()[0]

        def schedule(fixed):
            first_read = threading.Event()
            second_attempt = threading.Event()
            first_commit = threading.Event()
            errors = []
            outcomes = {}

            def await_event(event):
                if not event.wait(10):
                    raise TimeoutError("schedule did not reach synchronization point")

            def editor_a():
                with closing(connect()) as c:
                    try:
                        if fixed:
                            c.execute("BEGIN IMMEDIATE")
                            log("fixed A", "BEGIN IMMEDIATE")
                        initial = name(c)
                        log("fixed A" if fixed else "bad A", "read display_name", initial)
                        first_read.set()
                        await_event(second_attempt)
                        c.execute("UPDATE AppUser SET display_name=? WHERE user_id=1", (initial+"|A",))
                        if fixed:
                            c.execute("COMMIT")
                        log("fixed A" if fixed else "bad A", "write and commit", initial+"|A")
                        first_commit.set()
                    except BaseException as exc:
                        errors.append(repr(exc)); first_read.set(); first_commit.set()
                    finally:
                        c.close()

            def editor_b():
                with closing(connect()) as c:
                    try:
                        await_event(first_read)
                        if fixed:
                            try:
                                c.execute("BEGIN IMMEDIATE")
                                raise AssertionError("B unexpectedly obtained A's writer lock")
                            except sqlite3.OperationalError as exc:
                                assert exc.sqlite_errorcode == sqlite3.SQLITE_BUSY
                                outcomes["busy"] = dict(message=str(exc), code=exc.sqlite_errorcode, name=exc.sqlite_errorname)
                                log("fixed B", "BEGIN IMMEDIATE denied while A owns lock", outcomes["busy"])
                            second_attempt.set()
                            await_event(first_commit)
                            c.execute("BEGIN IMMEDIATE")
                            log("fixed B", "retry entire operation; BEGIN IMMEDIATE acquired")
                            initial = name(c)
                        else:
                            initial = name(c)
                            log("bad B", "read same old display_name", initial)
                            second_attempt.set()
                            await_event(first_commit)
                        log("fixed B" if fixed else "bad B", "read value used for update", initial)
                        c.execute("UPDATE AppUser SET display_name=? WHERE user_id=1", (initial+"|B",))
                        if fixed:
                            c.execute("COMMIT")
                        log("fixed B" if fixed else "bad B", "write and commit", initial+"|B")
                    except BaseException as exc:
                        errors.append(repr(exc)); second_attempt.set()
                    finally:
                        c.close()

            c = connect()
            c.execute("UPDATE AppUser SET display_name='base' WHERE user_id=1")
            c.close()
            threads = [threading.Thread(target=editor_a), threading.Thread(target=editor_b)]
            for thread in threads: thread.start()
            for thread in threads: thread.join(15)
            assert not any(t.is_alive() for t in threads), "thread did not finish"
            assert not errors, errors
            c = connect(); outcomes["final"] = name(c); c.close()
            assert outcomes["final"] == ("base|A|B" if fixed else "base|B")
            return outcomes

        bad = schedule(False)
        fixed = schedule(True)
        result = dict(sqlite=sqlite3.sqlite_version, fixture="unchanged A1 schema; one user/video", a1_t2=dict(before=old, after=new), retraction_rollback=True, handle_outcomes=handle_outcomes, bad=bad, fixed=fixed, events=events)
        output.write_text(json.dumps(result, indent=2))
        return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default=str(ROOT/"results/concurrency.json"))
    args = parser.parse_args()
    r = run(args.output)
    print(json.dumps({key:r[key] for key in ["a1_t2", "bad", "fixed", "handle_outcomes"]}, indent=2))
