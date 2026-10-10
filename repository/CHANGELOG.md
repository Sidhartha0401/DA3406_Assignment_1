# Assignment 2 changes to inherited code

Assignment 1 was kept read-only. Original-file hashes were checked during development; those audit files are retained locally and are not submitted.

1. `schema.sql` and `views.sql` are copied byte-for-byte. No schema redesign.
2. Generator default SCALE changes from 1 to 50. All four base volumes retain their original values and are multiplied by SCALE. Original fixed pools (15 categories, 20 hashtags, 3 models) remain fixed, so their counts are not expected to grow 50x.
3. OtherUsers is an index-mapped sequence replacing each materialized list of all users except one. It preserves population order, random.sample/random.choice results, and PRNG consumption. Four population sizes, including 250,000, were tested. This removes quadratic list construction at the mandatory scale.
4. The first real SCALE=50 run failed with `UNIQUE constraint failed: AppUser.auth_value`. The random phone pool permits collisions. Only colliding phone identities are redrawn. The failure log was retained locally during development and is not submitted. This is a necessary scale correctness repair and changes the random stream only after a collision.
5. Generator refuses to overwrite a database and resolves schema.sql relative to its own file. Progress messages are printed. Neither change alters generated data.
6. random_after bounds min_seconds by remaining seconds, preventing an invalid randint range near END_DATE. It retains the existing behavior for ordinary intervals.
7. F1 cutoff uses strftime to match the stored T/Z format, avoiding wrong lexicographic comparison on the boundary day. F1 and F9 have deterministic secondary sort keys. Stale A1 timing/count comment lines are removed; new measurements are presented in the report and plan_analysis.md; rerunning the driver creates experiments.json locally.
8. Literal Task 3 and Task 4 queries are appended to queries.sql. Original A1 query methods remain available, including their known non-blocking limitations.
9. Original transactions.sql statements remain intact with an added pointer to the actual runnable concurrency_demo.py. A1 referred to transactions.py, which was absent; A2 supplies a tested two-connection driver. The isolated fixture uses the unchanged A1 schema and does not alter benchmark data.

## Existing limitations retained deliberately

A1 has impressions before user registration/video upload, sparse prior-week rows in F10, no persistent cross-refresh suppression mechanism, globally rather than active-only unique handles, and a redundant model_name in Turn. They do not block the required storage/indexing/processing experiments; redesign would violate the A2 scope. Timings characterize this synthetic dataset, not production representativeness. A1 rolling reports and unrelated analytics are not presented as newly corrected results.

10. A second scaled load was deliberately interrupted after code review identified repeated full Follow scans during block handling. A load-only Follow(follower_id,followee_id,started_at) index is now built after follows, used for the exact same updates, and dropped before commit. It does not change PRNG consumption, data, schema or persisted baseline access paths. Cache is capped at 64 MiB and stage progress is logged. This avoids billions of row checks without tuning the measured queries. No aborted run is reported as a completed dataset.
