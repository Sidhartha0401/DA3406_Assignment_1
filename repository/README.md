# DA3406 Assignment 2 - ScrollSense

Sidhartha Durgam (DA24B003). SQLite storage, indexing and query-processing experiments using the Assignment 1 schema.

The submission contains the report PDF and this source repository. The measured results, plans, calculations and concurrency outcomes are presented in the PDF and `plan_analysis.md`. The `results/` folder is not submitted; it is created locally when reproducing the experiments.

## Files

- `schema.sql`, `views.sql`: unchanged A1 schema and consumer views.
- `generate_data.py`: seeded data generator, defaulting to SCALE=50.
- `queries.sql`, `transactions.sql`: inherited SQL and added A2 statements.
- `indexes.sql`: the three composite indexes tested in Task 2.
- `run_experiments.py`: integrity checks, query plans, before/after index timings, joins and predicate-pushdown comparisons.
- `concurrency_demo.sql`: annotated concurrent schedules.
- `concurrency_demo.py`: executable two-connection demonstrations.
- `plan_analysis.md`: measured results and explanations for Tasks 1-5.
- `tests.py`: regression checks for the generator optimization, SQL parser, result hashes, physical row counts and WAL behavior.
- `CHANGELOG.md`: changes to inherited A1 code.
- `REQUIREMENTS.md`: assignment coverage and where to find the submitted evidence.
- `requirements.txt`: optional dependencies used for PDF authoring during development; the experiment scripts do not need them.

## Environment

The original runs used Python 3.12.5 and Python's SQLite 3.45.3 on an Apple M1 with 8 GiB RAM. Python's SQLite must be version 3.44 or newer because the inherited SQL uses `group_concat(... ORDER BY ...)`. Check the Python driver:

```sh
python3 -c "import sys,sqlite3; print(sys.version); print(sqlite3.sqlite_version)"
```

All submitted Python scripts use the standard library. No package installation, dataset download or GPU is needed. Allow several GiB of local disk space for the database, WAL, indexes and temporary sorting. SCALE=50 generation can take tens of minutes.

## Reproduce the experiments

Run these commands from this repository directory. Start without an existing database at the chosen path; the generator refuses to overwrite one. `mkdir` creates the output folder, which is absent from the submission.

```sh
mkdir -p results
python3 -u generate_data.py --scale 50 --db results/scrollsense_scale50.db > results/generation.log 2>&1
python3 -u run_experiments.py --db results/scrollsense_scale50.db --output results/experiments.json --repeats 3 > results/experiments.log 2>&1
python3 concurrency_demo.py --output results/concurrency.json > results/concurrency.log 2>&1
python3 tests.py > results/tests.log 2>&1
```

The concurrency demonstration and regression tests can also run independently of the large dataset:

```sh
python3 concurrency_demo.py
python3 tests.py
```

`run_experiments.py` verifies the mandatory counts, database integrity and foreign keys. It records the baseline with the original A1 indexes, tests each new index separately, checks that query results are unchanged, and installs all three indexes for the join and pushdown experiments. Do not apply `indexes.sql` manually before collecting a baseline.

Each query has one warm-up and three measured runs. Timing includes execution and fetching all rows, and excludes hashing, plan extraction and index construction. The driver does not run `ANALYZE` or flush the OS cache. Timings and plans may vary with hardware, cache and SQLite version. It updates the J3 owner literal in `queries.sql` to match the generated dataset.

The selected inherited queries are F1, F12 and F11. The remaining A1 queries stay available in `queries.sql`. For optional consumer views on the generated database:

```sh
python3 -c "import sqlite3,pathlib; c=sqlite3.connect('results/scrollsense_scale50.db'); c.execute('PRAGMA foreign_keys=ON'); c.executescript(pathlib.Path('views.sql').read_text()); c.close()"
```

`concurrency_demo.sql` describes operations across multiple connections; execute `concurrency_demo.py` to reproduce them. The driver creates a small temporary fixture using the A1 schema and views. It demonstrates moderation visibility, rollback, handle-change rejection, a lost profile edit and its prevention with `BEGIN IMMEDIATE`.

## Generated outputs

Rerunning creates `results/generation.log`, `results/experiments.json`, `results/experiments.log`, `results/concurrency.json`, `results/concurrency.log` and `results/tests.log`, plus the generated database. These outputs are local and are ignored by Git. No pre-existing JSON or log files are needed to run the submitted scripts.

`experiments.json` contains counts, exact SQL, plans, trial timings, result hashes and storage cardinalities. `concurrency.json` contains outcomes and timestamped events. They describe the new execution; the original measurements remain in the submitted PDF and `plan_analysis.md`. The A1 comparison counts are also preserved in the report and analysis table.

The submitted repository reproduces the experiments. The PDF authoring script and development audit files are not included. Reproduction therefore does not require PDF regeneration or an Assignment 1 directory beside this repository.


