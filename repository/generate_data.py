"""
ScrollSense — generate_data.py

Generates realistic synthetic data and loads it into scrollsense.db.

Usage:
    python generate_data.py
    python generate_data.py --scale 50
    python generate_data.py --db my_database.db

SQLite 3.44+ required.
"""

import argparse
import json
import math
import os
import random
import sqlite3
from collections.abc import Sequence
from pathlib import Path
import time
from datetime import datetime, timedelta


# ================================================================
# Parameters
# ================================================================

SEED = "DA24B003"        # replace with your roll number
N_USERS = 5_000
N_VIDEOS = 20_000
N_IMPRESSIONS = 300_000
N_AGENT_SESSIONS = 2_000
SCALE = 50              # Assignment 2: set to 50
DB_PATH = "scrollsense.db"


parser = argparse.ArgumentParser()
parser.add_argument("--scale", type=int, default=SCALE)
parser.add_argument("--db", type=str, default=DB_PATH)
args = parser.parse_args()

if args.scale < 1:
    raise ValueError("scale must be >= 1")

SCALE = args.scale
DB_PATH = args.db

N_USERS *= SCALE
N_VIDEOS *= SCALE
N_IMPRESSIONS *= SCALE
N_AGENT_SESSIONS *= SCALE

random.seed(SEED)


# ================================================================
# Helpers
# ================================================================

BASE_DATE = datetime(2025, 1, 1)
END_DATE = BASE_DATE + timedelta(days=365)


def dt_to_str(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def str_to_dt(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")


def random_dt_between(start_dt, end_dt):
    if end_dt < start_dt:
        raise ValueError("end_dt must be >= start_dt")

    total_seconds = int((end_dt - start_dt).total_seconds())
    if total_seconds == 0:
        return dt_to_str(start_dt)

    offset = random.randint(0, total_seconds)
    return dt_to_str(start_dt + timedelta(seconds=offset))


def rand_dt(days_range=365):
    end = BASE_DATE + timedelta(days=days_range)
    return random_dt_between(BASE_DATE, end)


def daily_biased_dt(days_range=365):
    """Generate timestamps with higher activity in morning/evening."""
    while True:
        dt = BASE_DATE + timedelta(
            days=random.randint(0, days_range - 1),
            hours=random.randint(0, 23),
            minutes=random.randint(0, 59),
            seconds=random.randint(0, 59),
        )

        h = dt.hour

        if 6 <= h <= 11:
            weight = 1 + math.cos(math.pi * (h - 8) / 6)
        elif 17 <= h <= 23:
            weight = 1 + math.cos(math.pi * (h - 20) / 5)
        else:
            weight = 0.15

        if random.random() < weight / 2.0:
            return dt_to_str(dt)


def random_after(start_dt, max_dt=END_DATE, min_seconds=1):
    """Return a random timestamp strictly after start_dt."""
    if start_dt >= max_dt:
        return max_dt

    max_seconds = int((max_dt - start_dt).total_seconds())
    offset = random.randint(min(min_seconds, max_seconds), max_seconds)
    return min(start_dt + timedelta(seconds=offset), max_dt)


def power_law_int(n, exponent=1.8):
    if n <= 1:
        return 1
    return max(1, int(n * (random.random() ** exponent)))


def right_skewed_int(lo, hi):
    if hi <= lo:
        return lo
    return lo + int((hi - lo) * (random.random() ** 2.5))


def geom(p=0.4):
    k = 0
    while random.random() < p:
        k += 1
    return k


def canonical_handle(handle):
    return handle.casefold()


# ================================================================
# Static pools
# ================================================================

HANDLES = set()

HASHTAG_POOL = [
    "fyp", "trending", "viral", "scrollsense", "funny",
    "dance", "food", "travel", "music", "cat", "dog",
    "art", "gaming", "tech", "fashion", "fitness",
    "cooking", "memes", "relatable", "satisfying",
]

INTEREST_NAMES = [
    "Comedy", "Music", "Dance", "Food", "Travel",
    "Technology", "Fashion", "Fitness", "Gaming",
    "Art", "Sports", "Education", "Science", "Nature", "DIY",
]

TOOL_NAMES = [
    "search_videos",
    "get_user_history",
    "fetch_trending_audio",
    "get_creator_info",
    "search_hashtags",
]

TEMPLATE_NAMES = [
    "explain_why",
    "search_shelf",
    "conversational_search",
]

MODEL_NAMES = [
    "gpt-4o-mini",
    "llama-3.1-70b",
    "internal-finetune-v2",
]

VENDORS = {
    "gpt-4o-mini": "openai",
    "llama-3.1-70b": "meta",
    "internal-finetune-v2": "scrollsense",
}

TIERS = ["emerging", "rising", "established", "top"]


# ================================================================
# Handle generation
# ================================================================


def unique_handle():
    while True:
        handle = "user_" + str(random.randint(10_000, 9_999_999))
        if canonical_handle(handle) not in HANDLES:
            HANDLES.add(canonical_handle(handle))
            return handle


# ================================================================
# Open database
# ================================================================

if os.path.exists(DB_PATH):
    raise FileExistsError(f"Refusing to overwrite {DB_PATH}; choose a new --db path.")
started = time.perf_counter()
print(f"Generating SCALE={SCALE}, seed={SEED}, database={DB_PATH}", flush=True)

con = sqlite3.connect(DB_PATH)
con.execute("PRAGMA foreign_keys = ON;")
con.execute("PRAGMA journal_mode = WAL;")
con.execute("PRAGMA cache_size = -65536;")

with open(Path(__file__).with_name("schema.sql"), "r", encoding="utf-8") as schema_file:
    con.executescript(schema_file.read())

cur = con.cursor()
con.execute("BEGIN")


# ================================================================
# InterestCategory
# ================================================================

for category_id, name in enumerate(INTEREST_NAMES, start=1):
    cur.execute(
        "INSERT INTO InterestCategory(category_id, name) VALUES (?, ?)",
        (category_id, name),
    )

N_CATS = len(INTEREST_NAMES)


# ================================================================
# ModelPricing
# ================================================================

pricing_by_model = {}
pricing_id = 1

for model in MODEL_NAMES:
    vendor = VENDORS[model]

    periods = [
        ("2025-01-01T00:00:00Z", "2025-06-30T23:59:59Z"),
        ("2025-07-01T00:00:00Z", None),
    ]

    base_input = round(random.uniform(0.0001, 0.002), 6)
    base_output = round(base_input * random.uniform(2, 4), 6)
    base_cached = round(base_input * 0.1, 6)

    model_rows = []

    for idx, (valid_from, valid_to) in enumerate(periods):
        if idx == 0:
            input_rate = base_input
            output_rate = base_output
            cached_rate = base_cached
        else:
            input_rate = round(base_input * random.uniform(0.8, 1.3), 6)
            output_rate = round(base_output * random.uniform(0.8, 1.3), 6)
            cached_rate = round(input_rate * 0.1, 6)

        cur.execute(
            """
            INSERT INTO ModelPricing
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                pricing_id,
                model,
                vendor,
                input_rate,
                output_rate,
                cached_rate,
                valid_from,
                valid_to,
            ),
        )

        model_rows.append({
            "pricing_id": pricing_id,
            "valid_from": valid_from,
            "valid_to": valid_to,
        })

        pricing_id += 1

    pricing_by_model[model] = model_rows


def get_pricing_id(model, responded_at):
    """Select pricing for the chosen model and timestamp."""
    for row in pricing_by_model[model]:
        if row["valid_from"] <= responded_at and (
            row["valid_to"] is None or responded_at <= row["valid_to"]
        ):
            return row["pricing_id"]

    raise ValueError(
        f"No pricing row found for model={model}, time={responded_at}"
    )


# ================================================================
# PromptTemplate
# ================================================================

template_ids = []
template_created = {}
template_id = 1

for template_name in TEMPLATE_NAMES:
    n_versions = random.randint(3, 5)
    creation_base = BASE_DATE + timedelta(days=random.randint(0, 30))

    for version in range(1, n_versions + 1):
        created_dt = creation_base + timedelta(days=(version - 1) * 30)
        created_dt = min(created_dt, END_DATE - timedelta(days=1))

        text = (
            f"[{template_name} v{version}] "
            f"You are a helpful ScrollSense agent. "
            f"{'x' * random.randint(50, 200)}"
        )

        cur.execute(
            "INSERT INTO PromptTemplate VALUES (?, ?, ?, ?, ?)",
            (
                template_id,
                template_name,
                version,
                text,
                dt_to_str(created_dt),
            ),
        )

        template_ids.append(template_id)
        template_created[template_id] = created_dt
        template_id += 1


def pick_template_id(responded_dt):
    valid = [
        tid for tid in template_ids
        if template_created[tid] <= responded_dt
    ]

    if not valid:
        return min(template_ids, key=lambda tid: template_created[tid])

    return random.choice(valid)


# ================================================================
# AppUser
# ================================================================

user_ids = list(range(1, N_USERS + 1))
user_created_dt = {}
auth_values = set()

print('Generating users', flush=True)
for uid in user_ids:
    handle = unique_handle()
    display_name = f"User{uid}"
    auth_type = random.choice(["phone", "google"])

    if auth_type == "phone":
        auth_value = f"+91{random.randint(7_000_000_000, 9_999_999_999)}"
    else:
        auth_value = f"google_{uid}@gmail.com"

    # At 250,000 users the random phone pool can collide. Redraw only collisions.
    while auth_value in auth_values:
        auth_value = f"+91{random.randint(7_000_000_000, 9_999_999_999)}"
    auth_values.add(auth_value)

    created_dt = BASE_DATE + timedelta(
        days=random.randint(0, 300),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59),
    )

    user_created_dt[uid] = created_dt

    cur.execute(
        "INSERT INTO AppUser VALUES (?, ?, ?, ?, ?, ?)",
        (
            uid,
            handle,
            display_name,
            auth_type,
            auth_value,
            dt_to_str(created_dt),
        ),
    )


# ================================================================
# AccountStatusPeriod
# ================================================================

print('Generating account periods', flush=True)
status_period_id = 1

for uid in user_ids:
    user_start = user_created_dt[uid]
    roll = random.random()

    # Most users remain active.
    if roll < 0.93:
        cur.execute(
            "INSERT INTO AccountStatusPeriod VALUES (?, ?, ?, ?, ?)",
            (
                status_period_id,
                uid,
                "active",
                dt_to_str(user_start),
                None,
            ),
        )
        status_period_id += 1
        continue

    max_transition = min(
        user_start + timedelta(days=250),
        END_DATE - timedelta(days=1),
    )

    transition_dt = random_after(user_start, max_transition)
    next_status = "deactivated" if roll < 0.98 else "pending_deletion"

    cur.execute(
        "INSERT INTO AccountStatusPeriod VALUES (?, ?, ?, ?, ?)",
        (
            status_period_id,
            uid,
            "active",
            dt_to_str(user_start),
            dt_to_str(transition_dt),
        ),
    )
    status_period_id += 1

    cur.execute(
        "INSERT INTO AccountStatusPeriod VALUES (?, ?, ?, ?, ?)",
        (
            status_period_id,
            uid,
            next_status,
            dt_to_str(transition_dt),
            None,
        ),
    )
    status_period_id += 1


# ================================================================
# DeclaredInterest
# ================================================================

for uid in user_ids:
    n = random.randint(1, 5)
    categories = random.sample(range(1, N_CATS + 1), min(n, N_CATS))

    for cid in categories:
        cur.execute(
            "INSERT INTO DeclaredInterest VALUES (?, ?)",
            (uid, cid),
        )


# ================================================================
# InferredInterest
# ================================================================

print('Generating inferred interests', flush=True)
inference_id = 1

for uid in user_ids:
    n_categories = random.randint(1, 4)
    categories = random.sample(
        range(1, N_CATS + 1),
        min(n_categories, N_CATS),
    )

    for cid in categories:
        for week_offset in random.sample(
            range(1, 52),
            random.randint(4, 8),
        ):
            monday = BASE_DATE + timedelta(weeks=week_offset)
            monday -= timedelta(days=monday.weekday())

            confidence = round(random.betavariate(2, 3), 4)
            suppressed = 1 if random.random() < 0.05 else 0

            cur.execute(
                "INSERT INTO InferredInterest VALUES (?, ?, ?, ?, ?, ?)",
                (
                    inference_id,
                    uid,
                    cid,
                    confidence,
                    monday.strftime("%Y-%m-%d"),
                    suppressed,
                ),
            )

            inference_id += 1


# ================================================================
# CreatorPeriod + CreatorTierPeriod
# ================================================================

print('Generating creators', flush=True)
creator_user_ids = random.sample(
    user_ids,
    max(1, N_USERS // 7),
)

creator_period_map = {}
creator_period_id = 1
tier_period_id = 1

for uid in creator_user_ids:
    creator_start = user_created_dt[uid]

    cur.execute(
        "INSERT INTO CreatorPeriod VALUES (?, ?, ?, ?)",
        (
            creator_period_id,
            uid,
            dt_to_str(creator_start),
            None,
        ),
    )

    creator_period_map[uid] = creator_period_id

    n_tiers = random.randint(1, 3)
    tier_start = creator_start

    for tier_index in range(n_tiers):
        tier = TIERS[min(tier_index, len(TIERS) - 1)]

        if tier_index < n_tiers - 1:
            remaining_days = max(
                30,
                int((END_DATE - tier_start).total_seconds() / 86400),
            )
            max_days = max(30, min(120, remaining_days - 1))
            duration_days = random.randint(30, max_days)
            tier_end = tier_start + timedelta(days=duration_days)
            tier_end = min(tier_end, END_DATE - timedelta(days=1))
        else:
            tier_end = None

        cur.execute(
            "INSERT INTO CreatorTierPeriod VALUES (?, ?, ?, ?, ?)",
            (
                tier_period_id,
                creator_period_id,
                tier,
                dt_to_str(tier_start),
                dt_to_str(tier_end) if tier_end else None,
            ),
        )

        tier_period_id += 1

        if tier_end is None:
            break

        tier_start = tier_end

    creator_period_id += 1


# ================================================================
# AudioTrack
# ================================================================

print('Generating audio tracks', flush=True)
n_tracks = max(1, N_VIDEOS // 10)
track_ids = list(range(1, n_tracks + 1))
track_types = {}

for track_id in track_ids:
    track_type = "licensed" if random.random() < 0.30 else "original"
    track_types[track_id] = track_type

    cur.execute(
        "INSERT INTO AudioTrack VALUES (?, ?, ?)",
        (track_id, track_type, None),
    )


# ================================================================
# Video
# ================================================================

video_ids = list(range(1, N_VIDEOS + 1))
video_owner = {}
video_upload_dt = {}
video_caption_tags = {}

original_track_ids = [
    tid for tid in track_ids if track_types[tid] == "original"
]
random.shuffle(original_track_ids)

origin_videos = video_ids[:]
random.shuffle(origin_videos)
track_origin_map = dict(zip(original_track_ids, origin_videos))

print('Generating videos', flush=True)
for vid in video_ids:
    owner = (
        random.choice(creator_user_ids)
        if creator_user_ids and random.random() < 0.90
        else random.choice(user_ids)
    )

    video_owner[vid] = owner
    owner_created = user_created_dt[owner]

    latest_upload = min(
        owner_created + timedelta(days=365),
        END_DATE,
    )
    uploaded_dt = random_after(
        owner_created,
        latest_upload,
    ) if latest_upload > owner_created else owner_created

    video_upload_dt[vid] = uploaded_dt

    tags = random.sample(
        HASHTAG_POOL,
        random.randint(0, 3),
    )
    video_caption_tags[vid] = tags

    caption = (
        "Check this out! " + " ".join(f"#{tag}" for tag in tags)
        if tags else
        "Check this out!"
    )

    track = random.choice(track_ids) if random.random() < 0.70 else None
    duration_ms = random.randint(20_000, 90_000)

    cur.execute(
        "INSERT INTO Video VALUES (?, ?, ?, ?, ?, ?)",
        (
            vid,
            owner,
            track,
            duration_ms,
            caption,
            dt_to_str(uploaded_dt),
        ),
    )


for track_id, video_id in track_origin_map.items():
    cur.execute(
        """
        UPDATE AudioTrack
        SET original_video_id = ?
        WHERE track_id = ?
          AND track_type = 'original'
        """,
        (video_id, track_id),
    )


# ================================================================
# Hashtag + VideoHashtag
# ================================================================

hashtag_id_map = {}

for hashtag_id, tag in enumerate(HASHTAG_POOL, start=1):
    cur.execute(
        "INSERT INTO Hashtag VALUES (?, ?)",
        (hashtag_id, tag),
    )
    hashtag_id_map[tag] = hashtag_id

for vid in video_ids:
    for tag in video_caption_tags[vid]:
        cur.execute(
            "INSERT INTO VideoHashtag VALUES (?, ?)",
            (vid, hashtag_id_map[tag]),
        )


# ================================================================
# ModerationDecision
# ================================================================

print('Generating moderation decisions', flush=True)
moderation_decision_id = 1
video_mod_state = {}

for vid in video_ids:
    upload_dt = video_upload_dt[vid]

    pending_dt = random_after(
        upload_dt,
        min(upload_dt + timedelta(days=2), END_DATE),
    )

    cur.execute(
        "INSERT INTO ModerationDecision VALUES (?, ?, ?, ?, ?, ?)",
        (
            moderation_decision_id,
            vid,
            "pending",
            "classifier",
            None,
            dt_to_str(pending_dt),
        ),
    )
    moderation_decision_id += 1

    current_dt = pending_dt
    current_state = "pending"

    if random.random() < 0.85:
        live_dt = random_after(
            current_dt,
            min(current_dt + timedelta(days=2), END_DATE),
        )

        cur.execute(
            "INSERT INTO ModerationDecision VALUES (?, ?, ?, ?, ?, ?)",
            (
                moderation_decision_id,
                vid,
                "live",
                "classifier",
                None,
                dt_to_str(live_dt),
            ),
        )
        moderation_decision_id += 1

        current_dt = live_dt
        current_state = "live"

        if random.random() < 0.10:
            further_dt = random_after(
                current_dt,
                min(current_dt + timedelta(days=3), END_DATE),
            )

            further_state = random.choice(
                ["age_restricted", "demoted", "taken_down"]
            )
            actor_type = random.choice(["classifier", "human"])
            actor_id = random.randint(1, min(50, N_USERS)) if actor_type == "human" else None

            cur.execute(
                "INSERT INTO ModerationDecision VALUES (?, ?, ?, ?, ?, ?)",
                (
                    moderation_decision_id,
                    vid,
                    further_state,
                    actor_type,
                    actor_id,
                    dt_to_str(further_dt),
                ),
            )
            moderation_decision_id += 1
            current_state = further_state

    video_mod_state[vid] = current_state

live_videos = [
    vid for vid, state in video_mod_state.items() if state == "live"
]


# ================================================================
# Follow / Block / Mute
# ================================================================

class OtherUsers(Sequence):
    """Same ordered population as [u for u in user_ids if u != excluded].

    Avoid O(N_USERS**2) temporary-list construction. random.sample receives
    the same sequence length/order and consumes the same PRNG draws.
    """
    def __init__(self, excluded):
        self.excluded = excluded
    def __len__(self):
        return N_USERS - 1
    def __getitem__(self, index):
        if not 0 <= index < len(self):
            raise IndexError(index)
        value = index + 1
        return value + (value >= self.excluded)

print("Generating social graph", flush=True)
follow_id = 1
block_id = 1
mute_id = 1

for uid in user_ids:
    n_follows = power_law_int(50, exponent=2.0)
    targets = random.sample(
        OtherUsers(uid),
        min(n_follows, len(user_ids) - 1),
    )

    for target in targets:
        common_start = max(user_created_dt[uid], user_created_dt[target])
        latest_start = min(
            common_start + timedelta(days=250),
            END_DATE - timedelta(days=1),
        )
        started_dt = (
            random_after(common_start, latest_start)
            if latest_start > common_start
            else common_start
        )

        ended_dt = None
        if random.random() < 0.08:
            end_max = END_DATE
            if started_dt < end_max:
                ended_dt = random_after(started_dt, end_max)

        cur.execute(
            "INSERT INTO Follow VALUES (?, ?, ?, ?, ?)",
            (
                follow_id,
                uid,
                target,
                dt_to_str(started_dt),
                dt_to_str(ended_dt) if ended_dt else None,
            ),
        )
        follow_id += 1


# Blocks are generated after follows so we can end affected follows.
print("Applying blocks with a load-only index", flush=True)
con.execute("CREATE INDEX _load_follow_pair ON Follow(follower_id, followee_id, started_at)")
for uid in random.sample(user_ids, max(1, N_USERS // 20)):
    target = random.choice(OtherUsers(uid))

    blocked_dt = max(
        user_created_dt[uid],
        user_created_dt[target],
    ) + timedelta(days=random.randint(1, 250))
    blocked_dt = min(blocked_dt, END_DATE)
    blocked_at = dt_to_str(blocked_dt)

    cur.execute(
        "INSERT INTO Block VALUES (?, ?, ?, ?)",
        (
            block_id,
            uid,
            target,
            blocked_at,
        ),
    )

    # A block breaks an existing follow in BOTH directions.
    for follower, followee in ((uid, target), (target, uid)):
        cur.execute(
            """
            UPDATE Follow
            SET ended_at = ?
            WHERE follower_id = ?
              AND followee_id = ?
              AND started_at <= ?
              AND (ended_at IS NULL OR ended_at > ?)
            """,
            (
                blocked_at,
                follower,
                followee,
                blocked_at,
                blocked_at,
            ),
        )

    block_id += 1

con.execute("DROP INDEX _load_follow_pair")
print("Load-only index dropped; generating mutes and agent sessions", flush=True)

for uid in random.sample(user_ids, max(1, N_USERS // 15)):
    target = random.choice(OtherUsers(uid))

    started_dt = max(
        user_created_dt[uid],
        user_created_dt[target],
    ) + timedelta(days=random.randint(0, 180))
    started_dt = min(started_dt, END_DATE)

    cur.execute(
        "INSERT INTO Mute VALUES (?, ?, ?, ?, ?)",
        (
            mute_id,
            uid,
            target,
            dt_to_str(started_dt),
            None,
        ),
    )
    mute_id += 1


# ================================================================
# AgentSession + Turn + ToolCall + Recommendation
# ================================================================

session_id = 1
turn_id = 1
call_id = 1
recommendation_id = 1
score_id = 1          # surrogate PK for TurnQualityScore
rating_id = 1         # surrogate PK for UserTurnRating

# Recommendation metadata needed later when creating impressions.
recommendation_info = {}

for _ in range(N_AGENT_SESSIONS):
    uid = random.choice(user_ids)
    session_start = user_created_dt[uid] + timedelta(
        days=random.randint(0, 180)
    )
    session_start = min(session_start, END_DATE)

    cur.execute(
        "INSERT INTO AgentSession VALUES (?, ?, ?)",
        (
            session_id,
            uid,
            dt_to_str(session_start),
        ),
    )

    n_turns = random.randint(2, 7)
    turn_time = session_start

    for turn_order in range(1, n_turns + 1):
        turn_time = random_after(
            turn_time,
            min(turn_time + timedelta(minutes=10), END_DATE),
            min_seconds=30,
        )
        responded_at = dt_to_str(turn_time)

        model = random.choice(MODEL_NAMES)
        pricing_id_for_turn = get_pricing_id(model, responded_at)
        template_id_for_turn = pick_template_id(turn_time)

        temperature = (
            round(random.uniform(0.1, 1.2), 2)
            if random.random() > 0.10
            else None
        )
        input_tokens = random.randint(200, 2000)
        output_tokens = random.randint(50, 800)
        cached_tokens = random.randint(0, input_tokens // 2)

        cur.execute(
            "INSERT INTO Turn VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                turn_id,
                session_id,
                template_id_for_turn,
                pricing_id_for_turn,
                turn_order,
                f"User query {turn_id}",
                f"Assistant reply {turn_id}",
                model,
                temperature,
                input_tokens,
                output_tokens,
                cached_tokens,
                responded_at,
            ),
        )

        # ------------------------------------------------------------
        # Tool calls: actual parent-child nesting
        # ------------------------------------------------------------
        if random.random() < 0.60:
            n_calls = random.randint(1, 4)
            parent_id = None

            for call_index in range(n_calls):
                tool_name = random.choice(TOOL_NAMES)

                if tool_name == "search_videos":
                    arguments = {
                        "query": f"q{call_id}",
                        "filters": {"limit": random.randint(5, 20)},
                    }
                elif tool_name == "get_user_history":
                    arguments = {"days": random.randint(1, 30)}
                elif tool_name == "fetch_trending_audio":
                    arguments = {
                        "region": random.choice(["IN", "US", "GB", "SG"])
                    }
                elif tool_name == "get_creator_info":
                    arguments = {
                        "creator_id": random.choice(creator_user_ids)
                    }
                else:
                    arguments = {
                        "hashtag": random.choice(HASHTAG_POOL),
                        "limit": random.randint(5, 20),
                    }

                arguments_json = json.dumps(
                    arguments,
                    separators=(",", ":"),
                )

                if random.random() < 0.05:
                    result_text = None
                    errored = 1
                else:
                    # Plain TEXT result: JSON is reserved for arguments.
                    result_text = (
                        f"count={random.randint(0, 20)}; "
                        f"tool={tool_name}; "
                        f"call_id={call_id}"
                    )
                    errored = 0

                cur.execute(
                    "INSERT INTO ToolCall VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        call_id,
                        turn_id,
                        parent_id,
                        tool_name,
                        arguments_json,
                        result_text,
                        random.randint(20, 800),
                        errored,
                        responded_at,
                    ),
                )

                created_call_id = call_id
                call_id += 1

                # Build a chain when possible. This gives F9 real recursive
                # structures rather than only a flat list of calls.
                if call_index < n_calls - 1 and random.random() < 0.65:
                    parent_id = created_call_id
                else:
                    parent_id = None

        # ------------------------------------------------------------
        # Recommendations
        # ------------------------------------------------------------
        if random.random() < 0.40 and live_videos:
            n_recommendations = random.randint(3, 6)
            recommended_videos = random.sample(
                live_videos,
                min(n_recommendations, len(live_videos)),
            )

            for position, vid in enumerate(recommended_videos, start=1):
                cur.execute(
                    "INSERT INTO Recommendation VALUES (?, ?, ?, ?)",
                    (
                        recommendation_id,
                        turn_id,
                        vid,
                        position,
                    ),
                )

                # Store the recommendation's user and creation time so that
                # later impressions are tied to the same user and happen after
                # the recommendation was actually produced.
                recommendation_info[recommendation_id] = {
                    "user_id": uid,
                    "video_id": vid,
                    "recommended_at": turn_time,
                }

                recommendation_id += 1

        # ------------------------------------------------------------
        # Turn quality
        # ------------------------------------------------------------
        if random.random() < 0.30:
            cur.execute(
                "INSERT INTO TurnQualityScore VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    score_id,   # PK: independent counter, NOT turn_id
                    turn_id,    # FK -> Turn
                    round(random.uniform(1.0, 5.0), 2),
                    round(random.uniform(1.0, 5.0), 2),
                    round(random.uniform(1.0, 5.0), 2),
                    random.choice(MODEL_NAMES),
                    responded_at,
                ),
            )
            score_id += 1

        # ------------------------------------------------------------
        # User rating
        # ------------------------------------------------------------
        if random.random() < 0.05:
            rating_dt = min(
                turn_time + timedelta(seconds=random.randint(0, 300)),
                END_DATE,
            )

            cur.execute(
                "INSERT INTO UserTurnRating VALUES (?, ?, ?, ?)",
                (
                    rating_id,  # PK: independent counter, NOT turn_id
                    turn_id,    # FK -> Turn
                    random.choice(["up", "down"]),
                    dt_to_str(rating_dt),
                ),
            )
            rating_id += 1

        turn_id += 1

    session_id += 1


# ================================================================
# Impression + ViewSegment + Signals
# ================================================================

impression_id = 1
like_id = 1
retraction_id = 1
signal_id = 1
share_id = 1

weights = [
    power_law_int(N_VIDEOS, exponent=1.8)
    for _ in video_ids
]

total_weight = sum(weights)
cumulative_weights = []
running = 0

for weight in weights:
    running += weight
    cumulative_weights.append(running / total_weight)


def pick_video():
    r = random.random()
    lo = 0
    hi = len(cumulative_weights) - 1

    while lo < hi:
        mid = (lo + hi) // 2
        if cumulative_weights[mid] < r:
            lo = mid + 1
        else:
            hi = mid

    return video_ids[lo]


recommendation_ids = list(recommendation_info.keys())

print("Generating impressions and signals", flush=True)
for _ in range(N_IMPRESSIONS):
    if _ and _ % 1_000_000 == 0:
        print(f"  impressions: {_:,}; elapsed: {time.perf_counter()-started:.1f}s", flush=True)
    recommendation_id_for_impression = None

    if recommendation_ids and random.random() < 0.08:
        recommendation_id_for_impression = random.choice(recommendation_ids)
        info = recommendation_info[recommendation_id_for_impression]

        # Critical-link consistency:
        # same user + same video + impression after recommendation.
        uid = info["user_id"]
        vid = info["video_id"]
        rec_time = info["recommended_at"]
        impressed_dt = random_after(rec_time, END_DATE)
        impressed_at = dt_to_str(impressed_dt)
    else:
        uid = random.choice(user_ids)
        vid = pick_video()
        impressed_at = daily_biased_dt()

    feed_position = random.randint(1, 30)
    model_version = random.choice(["rank-v1", "rank-v2", "rank-v3"])

    cur.execute(
        "INSERT INTO Impression VALUES (?, ?, ?, ?, ?, ?, ?)",
        (
            impression_id,
            uid,
            vid,
            recommendation_id_for_impression,
            feed_position,
            model_version,
            impressed_at,
        ),
    )

    # ------------------------------------------------------------
    # View funnel
    # ------------------------------------------------------------
    if random.random() < 0.40:
        n_segments = 1 + geom(0.25)
        offset_ms = 0

        row = cur.execute(
            "SELECT duration_ms FROM Video WHERE video_id = ?",
            (vid,),
        ).fetchone()
        duration_ms = row[0]

        for _segment in range(n_segments):
            remaining = max(1, duration_ms - offset_ms)

            segment_length = right_skewed_int(
                300,
                remaining,
            )

            end_ms = min(
                duration_ms,
                offset_ms + segment_length,
            )

            completed = 1 if end_ms >= duration_ms else 0

            cur.execute(
                "INSERT INTO ViewSegment VALUES (?, ?, ?, ?)",
                (
                    impression_id,
                    offset_ms,
                    end_ms,
                    completed,
                ),
            )

            if end_ms >= duration_ms:
                break

            offset_ms = min(
                duration_ms - 1,
                end_ms + random.randint(0, 2000),
            )

        # --------------------------------------------------------
        # Like + optional retraction
        # --------------------------------------------------------
        if random.random() < 0.08:
            liked_dt = str_to_dt(impressed_at)

            cur.execute(
                "INSERT INTO Like VALUES (?, ?, ?, ?)",
                (
                    like_id,
                    uid,
                    vid,
                    impressed_at,
                ),
            )

            if random.random() < 0.12:
                retracted_dt = min(
                    liked_dt + timedelta(seconds=random.randint(0, 120)),
                    END_DATE,
                )

                cur.execute(
                    "INSERT INTO LikeRetraction VALUES (?, ?, ?)",
                    (
                        retraction_id,
                        like_id,
                        dt_to_str(retracted_dt),
                    ),
                )
                retraction_id += 1

            like_id += 1

        # --------------------------------------------------------
        # Other explicit signals
        # --------------------------------------------------------
        if random.random() < 0.03:
            cur.execute(
                "INSERT INTO ExplicitSignal VALUES (?, ?, ?, ?, ?)",
                (
                    signal_id,
                    uid,
                    vid,
                    random.choice([
                        "save",
                        "comment",
                        "follow_from_feed",
                        "not_interested",
                        "report",
                    ]),
                    impressed_at,
                ),
            )
            signal_id += 1

        # --------------------------------------------------------
        # Shares
        # --------------------------------------------------------
        if random.random() < 0.015:
            cur.execute(
                "INSERT INTO Share VALUES (?, ?, ?, ?, ?)",
                (
                    share_id,
                    uid,
                    vid,
                    random.choice([
                        "whatsapp",
                        "instagram",
                        "copied_link",
                    ]),
                    impressed_at,
                ),
            )
            share_id += 1

    impression_id += 1


# ================================================================
# Commit
# ================================================================

con.execute("COMMIT")
con.close()

print(f"Done. Database written to {DB_PATH}")
print(f"  Users:           {N_USERS:,}")
print(f"  Videos:          {N_VIDEOS:,}")
print(f"  Impressions:     {N_IMPRESSIONS:,}")
print(f"  Agent sessions:  {N_AGENT_SESSIONS:,}")

print(f"Elapsed seconds: {time.perf_counter()-started:.3f}", flush=True)
