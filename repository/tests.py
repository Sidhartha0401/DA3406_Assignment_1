"""Meaningful regression checks for the scale optimization and SQL harness."""
import ast
import random
import sqlite3
import unittest
from collections.abc import Sequence
from pathlib import Path
from run_experiments import statements, digest, table_storage

ROOT = Path(__file__).resolve().parent


class RegressionTests(unittest.TestCase):
    def test_iso_timestamp_cutoff_preserves_time_on_boundary_day(self):
        c=sqlite3.connect(':memory:')
        timestamp='2025-12-25T01:00:00Z';maximum='2026-01-01T12:00:00Z'
        wrong=c.execute("SELECT ? >= datetime(?,'-7 days')",(timestamp,maximum)).fetchone()[0]
        correct=c.execute("SELECT ? >= strftime('%Y-%m-%dT%H:%M:%SZ',?,'-7 days')",(timestamp,maximum)).fetchone()[0]
        self.assertEqual(wrong,1);self.assertEqual(correct,0);c.close()

    def test_physical_leaf_cells_match_sql_rows(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            db=Path(tmp)/'pages.db';c=sqlite3.connect(db)
            c.execute('CREATE TABLE Data(id INTEGER PRIMARY KEY,value TEXT)')
            c.executemany('INSERT INTO Data VALUES(?,?)',((i,'payload'*20) for i in range(2000)))
            c.commit();root=c.execute("SELECT rootpage FROM sqlite_master WHERE name='Data'").fetchone()[0]
            size=c.execute('PRAGMA page_size').fetchone()[0];c.close()
            result=table_storage(db,root,size)
            self.assertEqual(result['cells'],2000)
            self.assertGreater(result['leaf_pages'],1)
            self.assertGreater(result['interior_pages'],0)

    def test_user_population_optimization_preserves_random_stream(self):
        tree = ast.parse((ROOT/"generate_data.py").read_text())
        cls = next(node for node in tree.body if isinstance(node,ast.ClassDef) and node.name=="OtherUsers")
        for size in [2,30,5000,250000]:
            scope = {"Sequence":Sequence,"N_USERS":size}
            exec(compile(ast.Module(body=[cls],type_ignores=[]),"OtherUsers","exec"),scope)
            for excluded in [1,size//2 or 1,size]:
                pool=scope["OtherUsers"](excluded)
                original=[u for u in range(1,size+1) if u!=excluded]
                random.seed("DA24B003"); a=random.sample(original,min(50,size-1)); state=random.getstate()
                random.seed("DA24B003"); b=random.sample(pool,min(50,size-1))
                self.assertEqual(a,b);self.assertEqual(state,random.getstate())

    def test_sql_parser_preserves_semicolons_in_string_literals(self):
        queries=statements(ROOT/"queries.sql")
        # First 16 statements are inherited A1 queries; later blocks are A2.
        self.assertGreaterEqual(len(queries),16)
        self.assertIn("';'",queries[5])
        self.assertIn("session_id = 1",queries[13])

    def test_result_digest_retains_multiplicity(self):
        self.assertEqual(digest([(1,),(2,)]),digest([(2,),(1,)]))
        self.assertNotEqual(digest([(1,),(1,)]),digest([(1,)]))

    def test_native_wal_snapshot_rejects_stale_upgrade(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            db=Path(tmp)/"snapshot.db"
            a=sqlite3.connect(db,isolation_level=None,timeout=0)
            b=sqlite3.connect(db,isolation_level=None,timeout=0)
            a.execute("PRAGMA journal_mode=WAL")
            a.execute("CREATE TABLE Profile(display_name TEXT)")
            a.execute("INSERT INTO Profile VALUES('base')")
            a.execute("BEGIN");b.execute("BEGIN")
            a.execute("SELECT * FROM Profile").fetchall();b.execute("SELECT * FROM Profile").fetchall()
            a.execute("UPDATE Profile SET display_name='base|A'");a.execute("COMMIT")
            with self.assertRaises(sqlite3.OperationalError) as caught:
                b.execute("UPDATE Profile SET display_name='base|B'")
            self.assertEqual(caught.exception.sqlite_errorname,"SQLITE_BUSY_SNAPSHOT")
            b.execute("ROLLBACK");a.close();b.close()


if __name__=="__main__":
    unittest.main(verbosity=2)
