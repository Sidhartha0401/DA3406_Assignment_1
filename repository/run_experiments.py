"""Record real SQLite plans/timings; each composite index is tested in isolation."""
import argparse
import hashlib
import json
import platform
import sqlite3
import statistics
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def table_storage(db, root_page, page_size):
    """Count rowid-table leaf pages/cells from a CHECKPOINTED SQLite file.

    SQLite fileformat2: interior table 0x05, leaf table 0x0d;
    all rowid-table records live in leaves. No dbstat extension is required.
    Overflow/index pages are deliberately excluded from this cardinality.
    """
    pending=[root_page];seen=set();leaves=0;cells=0;interior=0
    with Path(db).open('rb') as f:
        while pending:
            number=pending.pop()
            assert number not in seen, 'B-tree cycle'
            seen.add(number);f.seek((number-1)*page_size);page=f.read(page_size)
            assert len(page)==page_size
            offset=100 if number==1 else 0
            kind=page[offset];n=int.from_bytes(page[offset+3:offset+5],'big')
            if kind==13:
                leaves+=1;cells+=n
            elif kind==5:
                interior+=1
                pending.append(int.from_bytes(page[offset+8:offset+12],'big'))
                for j in range(n):
                    ptr=int.from_bytes(page[offset+12+2*j:offset+14+2*j],'big')
                    pending.append(int.from_bytes(page[ptr:ptr+4],'big'))
            else:
                raise ValueError(f'Expected rowid-table B-tree; page {number}, type {kind}')
    return dict(leaf_pages=leaves,cells=cells,interior_pages=interior,
                source='read-only SQLite B-tree traversal; checkpointed file')


def statements(path):
    buffer = ""
    result = []
    for line in Path(path).read_text().splitlines(True):
        buffer += line
        if sqlite3.complete_statement(buffer):
            if "PRAGMA foreign_keys" not in buffer:
                result.append(buffer.strip())
            buffer = ""
    return result


def digest(rows):
    # Ignore presentation order, retain duplicate multiplicities.
    values = sorted(json.dumps(row, separators=(",", ":")) for row in rows)
    return hashlib.sha256("\n".join(values).encode()).hexdigest()


EXTRA = {
    "J1": """SELECT count(*) AS segments, sum(vs.segment_end_ms-vs.segment_start_ms) AS watch_ms
FROM ViewSegment vs JOIN Impression i ON i.impression_id=vs.impression_id;""",
    "J2": """SELECT count(*) AS calls, sum(tc.latency_ms) AS latency_ms
FROM ToolCall tc JOIN Turn t ON t.turn_id=tc.turn_id;""",
    "J3": """SELECT count(*) AS completed_segments
FROM Video v JOIN Impression i ON i.video_id=v.video_id
JOIN ViewSegment vs ON vs.impression_id=i.impression_id
WHERE v.owner_id=461 AND vs.completed=1;""",
    "P_naive": """SELECT joined.call_id, joined.turn_id, joined.session_id, joined.tool_name
FROM (SELECT tc.call_id,tc.turn_id,t.session_id,tc.tool_name
      FROM ToolCall tc JOIN Turn t ON t.turn_id=tc.turn_id
      WHERE tc.parent_call_id IS NULL) joined
WHERE joined.session_id=1 ORDER BY joined.call_id;""",
    "P_pushed": """SELECT tc.call_id,tc.turn_id,t.session_id,tc.tool_name
FROM ToolCall tc JOIN (SELECT turn_id,session_id FROM Turn WHERE session_id=1) t
ON t.turn_id=tc.turn_id WHERE tc.parent_call_id IS NULL ORDER BY tc.call_id;""",
}


def run(db, output, repeats=3):
    if repeats < 3:
        raise ValueError("use at least three measured executions")
    c = sqlite3.connect(db, cached_statements=0)
    c.execute("PRAGMA foreign_keys=ON")
    c.execute("PRAGMA cache_size=-65536")
    c.execute("PRAGMA temp_store=FILE")
    assert sqlite3.sqlite_version_info >= (3,44,0)
    assert c.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    indexes = [q for q in statements(ROOT/"indexes.sql")]
    names = ["a2_impression_time_video", "a2_segment_completed_impression", "a2_toolcall_parent_turn"]

    def clean():
        for name in names:
            c.execute(f"DROP INDEX IF EXISTS {name}")
        c.commit()

    def measure(label, sql):
        plan = [list(row) for row in c.execute("EXPLAIN QUERY PLAN "+sql)]
        times = []
        expected = None
        for trial in range(repeats+1):
            start = time.perf_counter()
            rows = c.execute(sql).fetchall()
            elapsed = time.perf_counter()-start
            signature = digest(rows)
            if expected is None:
                expected = signature
            assert signature == expected, f"unstable results: {label}"
            if trial:
                times.append(elapsed)
            print(f"{label}: {'warmup' if trial==0 else trial}, rows={len(rows)}, seconds={elapsed:.6f}", flush=True)
        return dict(sql=sql, plan=plan, seconds=times, median_seconds=statistics.median(times), rows=len(rows), first5=rows[:5], sha256=expected)

    clean()
    tables = [row[0] for row in c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    counts = {table:c.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0] for table in tables}
    assert [counts[t] for t in ["AppUser","Video","Impression","AgentSession"]] == [250000,1000000,15000000,100000]
    assert not c.execute("PRAGMA foreign_key_check").fetchall()
    assert c.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    page_size = c.execute("PRAGMA page_size").fetchone()[0]
    # The macOS Python SQLite build lacks dbstat. Checkpoint, then inspect only
    # immutable table-page structure, verifying cell totals against SQL counts.
    checkpoint=c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    assert checkpoint[0]==0, 'cannot safely inspect an uncheckpointed file'
    storage = {}
    for table in ["Impression","ViewSegment","Video","Turn","ToolCall"]:
        root_page=c.execute("SELECT rootpage FROM sqlite_master WHERE type='table' AND name=?",(table,)).fetchone()[0]
        storage[table]=table_storage(db,root_page,page_size)
        assert storage[table]['cells']==counts[table], 'physical row count mismatch'
    queries = statements(ROOT/"queries.sql")
    chosen = {"F1":queries[0], "F12":queries[14], "F11":queries[13]}
    result = dict(configuration=dict(seed="DA24B003", scale=50, repeats=repeats, warmups=1, cache_kib=65536, temp_store="FILE", automatic_index=c.execute("PRAGMA automatic_index").fetchone()[0], sqlite=sqlite3.sqlite_version, python=platform.python_version(), platform=platform.platform(), architecture=platform.machine(), page_size=page_size, timer="perf_counter; execute+fetchall; exclude hash/plan/index-build", order="baseline and each isolated index; OS cache not flushed"), counts=counts, storage=storage, task1={}, task2={}, joins={}, pushdown={})
    result["baseline_max_opcodes"]=[list(row) for row in c.execute("EXPLAIN SELECT MAX(impressed_at) FROM Impression") if row[1] in ["OpenRead","Rewind","Next","Last","SeekRowid"]]
    # Raw result checkpoint after every experiment, so interrupted work is honest.
    output = Path(output); output.parent.mkdir(parents=True,exist_ok=True)
    def save(): output.write_text(json.dumps(result,indent=2))
    for label, sql in chosen.items():
        result["task1"][label] = measure(label+" baseline", sql);save()
    for (label, sql), name, ddl in zip(chosen.items(), names, indexes):
        clean()
        start = time.perf_counter(); c.execute(ddl);c.commit();build=time.perf_counter()-start
        after = measure(label+" indexed", sql)
        assert after["sha256"] == result["task1"][label]["sha256"], f"index changed results for {label}"
        result["task2"][label] = dict(index=name, ddl=ddl, build_seconds=build, before=result["task1"][label], after=after);save()
    clean()
    c.executescript((ROOT/"indexes.sql").read_text());c.commit()
    # Use a real owner with at least one video; the first video's owner is a
    # deterministic selection independent of plans, not an A1 literal that
    # may happen to have no clips after scaling/reseeding distributions.
    owner=c.execute("SELECT owner_id FROM Video ORDER BY video_id LIMIT 1").fetchone()[0]
    join3_sql=EXTRA["J3"].replace("v.owner_id=461",f"v.owner_id={owner}")
    result["selectivity"] = dict(owner=owner, selected_videos=c.execute("SELECT count(*) FROM Video WHERE owner_id=?",(owner,)).fetchone()[0], completed_segments=c.execute("SELECT count(*) FROM ViewSegment WHERE completed=1").fetchone()[0], session1_turns=c.execute("SELECT count(*) FROM Turn WHERE session_id=1").fetchone()[0])
    result["join_order_prediction"] = dict(chosen_before_plan="Video -> Impression -> filtered ViewSegment (logical smallest intermediate heuristic)", estimated_first_join=counts["Impression"]*result["selectivity"]["selected_videos"]/counts["Video"], estimated_final=result["selectivity"]["completed_segments"]*result["selectivity"]["selected_videos"]/counts["Video"], caveat="no video_id-leading Impression index; physical access can favor completion first")
    # Save the exact chosen literal SQL in the required updated query file.
    query_text=(ROOT/"queries.sql").read_text()
    import re
    query_text=re.sub(r"-- J3\n.*?;", "-- J3\n"+join3_sql,query_text,flags=re.S)
    (ROOT/"queries.sql").write_text(query_text)
    save()
    for label in ["J1","J2","J3"]:
        result["joins"][label] = measure(label, join3_sql if label=="J3" else EXTRA[label]);save()
    for label in ["P_naive","P_pushed"]:
        result["pushdown"][label] = measure(label, EXTRA[label]);save()
    assert result["pushdown"]["P_naive"]["sha256"] == result["pushdown"]["P_pushed"]["sha256"]
    result["pushdown_opcodes"]={label:[list(row) for row in c.execute("EXPLAIN "+EXTRA[label]) if row[1] in ["OpenRead","Rewind","Next","SeekRowid","SeekGE","IdxGT","Column","Ne","NotNull","ResultRow","SorterInsert"]] for label in ["P_naive","P_pushed"]}
    # Collect VM evidence: cursor OpenRead / SeekRowid / Next identify loop execution.
    result["join_opcodes"] = {label:[list(row) for row in c.execute("EXPLAIN "+EXTRA[label]) if row[1] in ["OpenRead","Rewind","Next","SeekRowid","SeekGE","IdxGT"]] for label in ["J1","J2"]}
    result["final_indexes"] = [list(row) for row in c.execute("SELECT name,sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL")]
    result["verified"] = dict(integrity="ok", foreign_key_violations=0, all_core_scale_counts_exact=True, index_results_equal=True, pushdown_results_equal=True)
    result["source_sha256"]={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ["schema.sql","generate_data.py","queries.sql","indexes.sql","run_experiments.py"]}
    result["execution_command"]="python3 -u run_experiments.py --db results/scrollsense_scale50.db --output results/experiments.json --repeats "+str(repeats)
    save();c.close()
    return result


if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("--db",type=Path,default=ROOT/"results/scrollsense_scale50.db")
    parser.add_argument("--output",type=Path,default=ROOT/"results/experiments.json")
    parser.add_argument("--repeats",type=int,default=3)
    args=parser.parse_args();run(args.db,args.output,args.repeats)
