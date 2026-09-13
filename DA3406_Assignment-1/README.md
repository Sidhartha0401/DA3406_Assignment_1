# ScrollSense Database Architecture

**Author:** Sidhartha Durgam (DA24B003)

A robust relational database schema, synthetic data generator, and analytics pipeline for **ScrollSense**, a short-video application featuring an integrated LLM agent.

## Prerequisites
* Python 3.x.
* SQLite 3.44 or later. This version is strictly required to support window functions, recursive CTEs, and `group_concat` with `ORDER BY`.

## How to Run (Execution Order)

To build the database and run all queries from a completely empty state, execute the files in this exact order:

1. **Build the Schema:** Run `sqlite3 scrollsense.db < schema.sql`. This initializes the database, creates all tables with proper domain constraints, and explicitly enables required PRAGMAs.
2. **Generate Synthetic Data:** Run `python generate_data.py`. This populates `scrollsense.db` with 5,000 users, 20,000 videos, 300,000 impressions, and 2,000 agent sessions.
3. **Create Views:** Run `sqlite3 scrollsense.db < views.sql`. This step creates the five consumer-facing views required for the mobile client, Trust & Safety, Growth analysts, and Finance.
4. **Execute Core Queries:** Run `sqlite3 scrollsense.db < queries.sql`. This script executes all 13 Tier 1 and Tier 2 analytics queries (Deliverable F).
5. **Demonstrate Transactions:** Run `sqlite3 scrollsense.db < transactions.sql`. This file tests transaction atomicity, WAL read isolation, and `SQLITE_BUSY` concurrency locks.

## Important Notes & Constraints

* **Connection PRAGMAs:** SQLite does not enforce foreign keys by default. The statements `PRAGMA foreign_keys = ON;` and `PRAGMA journal_mode = WAL;` are required and must be executed per connection.
* **Data Scaling:** To generate a larger dataset, you can run the python generator with a scale flag, for example: `python generate_data.py --scale 50`.
* **Timestamps:** All dates and times in this schema are stored uniformly as ISO-8601 text strings. This ensures safe string comparisons and allows date arithmetic using `julianday()`.
