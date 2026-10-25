#!/usr/bin/env python3
"""Measure how long a full library snapshot takes.

The app refreshes its whole in-memory snapshot after every change, so the cost
of one `snapshot()` is what the user feels when they star, tag, or file an
item. This script builds a library with the same tables the app uses, fills it
with synthetic Markdown, and times the queries `LibraryRepository.snapshot()`
runs.

    ./script/snapshot-benchmark.py --documents 10000 --chars 20000

The old query selected `substr(body, 1, 240)`, `length(trim(body))` and
`instr(body, ...)` from every row, which makes SQLite read every body off its
overflow pages. `--mode columns` measures the shape the app uses now, where
those three values are stored next to the row.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sqlite3
import statistics
import sys
import tempfile
import time

WORDS = ["合同", "甲方", "乙方", "条款", "验收", "付款", "流程", "风险", "备份", "迁移", "检索", "目录"]
SENTENCE = "本合同由双方在平等自愿的基础上订立，任何一方不得擅自变更条款。"


def body_for(index: int, chars: int, rng: random.Random) -> str:
    head = f"# 第 {index} 份资料\n\n" + "".join(rng.choice(WORDS) for _ in range(20)) + "\n\n"
    filler = SENTENCE * (chars // len(SENTENCE) + 1)
    if index % 10 == 0:
        filler += "\n\n参考 [文档](https://example.com/doc)\n"
    if index % 7 == 0:
        filler += "\n\n![图](images/a.png)\n"
    return head + filler[: max(0, chars - len(head))]


def build(path: str, documents: int, chars: int, seed: int) -> None:
    rng = random.Random(seed)
    db = sqlite3.connect(path)
    db.executescript(
        """
        PRAGMA journal_mode = OFF;
        CREATE TABLE collections (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, parent_id TEXT);
        CREATE TABLE items (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
            relative_path TEXT, body TEXT NOT NULL, extraction_note TEXT,
            byte_count INTEGER NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL,
            collection_id TEXT, favorite INTEGER NOT NULL DEFAULT 0,
            image_base_path TEXT, deleted_at REAL, fingerprint TEXT,
            ocr_version INTEGER NOT NULL DEFAULT 0, reading_position TEXT
        );
        CREATE TABLE markdown_images (
            item_id TEXT NOT NULL, reference TEXT NOT NULL, relative_path TEXT, failure TEXT,
            PRIMARY KEY (item_id, reference)
        );
        CREATE TABLE item_sources (item_id TEXT NOT NULL, path TEXT NOT NULL);
        CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE);
        CREATE TABLE item_tags (item_id TEXT NOT NULL, tag_id TEXT NOT NULL, PRIMARY KEY (item_id, tag_id));
        CREATE TABLE activities (id TEXT PRIMARY KEY, message TEXT NOT NULL, date REAL NOT NULL);
        """
    )
    rows = []
    images = []
    for index in range(documents):
        body = body_for(index, chars, rng)
        item_id = f"item-{index:06d}"
        now = 1_700_000_000 + index
        rows.append((item_id, f"第 {index} 份资料", "document", None, body, None,
                     len(body.encode()), now, now, None, 0, None, None, f"fp{index}", 0, None))
        images.append((item_id, "images/a.png", None, None))
    db.executemany("INSERT INTO items VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    db.executemany("INSERT INTO markdown_images VALUES (?,?,?,?)", images)
    db.executemany("INSERT INTO item_sources VALUES (?,?)",
                   [(r[0], f"/Users/someone/docs/{r[0]}.md") for r in rows])
    db.executemany("INSERT INTO tags VALUES (?,?)", [(f"t{i}", f"标签{i}") for i in range(12)])
    db.executemany("INSERT INTO item_tags VALUES (?,?)",
                   [(r[0], f"t{int(r[0].split('-')[1]) % 12}") for r in rows])
    db.executemany("INSERT INTO activities VALUES (?,?,?)",
                   [(f"a{i}", f"记录 {i}", 1_700_000_000 + i) for i in range(200)])
    db.commit()
    db.close()


OLD_ITEMS = """
    SELECT id, title, kind, relative_path, substr(body, 1, 240) AS preview,
           extraction_note, byte_count, created_at, updated_at, collection_id,
           favorite, image_base_path, deleted_at,
           length(trim(body)) > 0 AS has_body,
           instr(body, '](http') > 0 OR instr(body, '<http') > 0 AS has_links
    FROM items WHERE deleted_at IS NULL ORDER BY updated_at DESC, id
"""

NEW_ITEMS = """
    SELECT id, title, kind, relative_path, preview,
           extraction_note, byte_count, created_at, updated_at, collection_id,
           favorite, image_base_path, deleted_at, has_body, has_links
    FROM items WHERE deleted_at IS NULL ORDER BY updated_at DESC, id
"""

SUPPORT = [
    "SELECT * FROM markdown_images ORDER BY reference",
    "SELECT * FROM item_sources ORDER BY path",
    """SELECT item_tags.item_id AS item_id, tags.name AS name FROM item_tags
       JOIN tags ON tags.id = item_tags.tag_id ORDER BY tags.name COLLATE NOCASE""",
    "SELECT * FROM collections ORDER BY name COLLATE NOCASE",
    "SELECT * FROM activities ORDER BY date DESC LIMIT 200",
]


def time_once(db: sqlite3.Connection, statements: list[str]) -> float:
    started = time.perf_counter()
    for statement in statements:
        db.execute(statement).fetchall()
    return (time.perf_counter() - started) * 1000


def breakdown(path: str, rounds: int) -> list[dict]:
    """Per-statement cost, so the next bottleneck is visible."""
    db = sqlite3.connect(path)
    statements = [("items", NEW_ITEMS)] + [
        ("images", SUPPORT[0]), ("sources", SUPPORT[1]),
        ("tags", SUPPORT[2]), ("collections", SUPPORT[3]), ("activities", SUPPORT[4]),
    ]
    timings = {name: [] for name, _ in statements}
    for _ in range(rounds):
        for name, statement in statements:
            started = time.perf_counter()
            db.execute(statement).fetchall()
            timings[name].append((time.perf_counter() - started) * 1000)
    db.close()
    return [{"statement": name, "p50_ms": round(statistics.median(samples), 1)}
            for name, samples in timings.items()]


def measure(path: str, mode: str, rounds: int) -> dict:
    db = sqlite3.connect(path)
    items = OLD_ITEMS if mode == "body" else NEW_ITEMS
    statements = [items] + SUPPORT
    samples = []
    for _ in range(rounds):
        samples.append(time_once(db, statements))
    db.close()
    samples.sort()
    return {
        "mode": mode,
        "p50_ms": round(statistics.median(samples), 1),
        "p95_ms": round(samples[min(len(samples) - 1, int(len(samples) * 0.95))], 1),
        "min_ms": round(samples[0], 1),
        "max_ms": round(samples[-1], 1),
    }


def derived_columns(path: str) -> float:
    """Writes the three derived columns the way the migration does."""
    db = sqlite3.connect(path)
    db.executescript(
        """
        ALTER TABLE items ADD COLUMN preview TEXT;
        ALTER TABLE items ADD COLUMN has_body INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE items ADD COLUMN has_links INTEGER NOT NULL DEFAULT 0;
        """
    )
    started = time.perf_counter()
    db.execute(
        """UPDATE items SET preview = substr(body, 1, 240),
                  has_body = length(trim(body)) > 0,
                  has_links = instr(body, '](http') > 0 OR instr(body, '<http') > 0"""
    )
    db.commit()
    elapsed = (time.perf_counter() - started) * 1000
    db.close()
    return elapsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--documents", type=int, default=10000)
    parser.add_argument("--chars", type=int, default=20000)
    parser.add_argument("--rounds", type=int, default=9)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--database", help="reuse an existing file instead of building one")
    parser.add_argument("--keep", action="store_true", help="keep the temporary database")
    arguments = parser.parse_args()

    path = arguments.database
    if not path:
        handle, path = tempfile.mkstemp(suffix=".sqlite", prefix="snapshot-bench-")
        os.close(handle)
        os.unlink(path)
        started = time.perf_counter()
        build(path, arguments.documents, arguments.chars, arguments.seed)
        build_ms = round((time.perf_counter() - started) * 1000, 1)
    else:
        build_ms = None

    size_mb = round(os.path.getsize(path) / 1024 / 1024, 1)
    before = measure(path, "body", arguments.rounds)
    derived_ms = derived_columns(path)
    after = measure(path, "columns", arguments.rounds)
    detail = breakdown(path, arguments.rounds)

    report = {
        "database": path,
        "size_mb": size_mb,
        "documents": arguments.documents,
        "chars": arguments.chars,
        "build_ms": build_ms,
        "derived_backfill_ms": round(derived_ms, 1),
        "before": before,
        "after": after,
        "speedup": round(before["p50_ms"] / max(after["p50_ms"], 0.001), 2),
        "breakdown": detail,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if not arguments.keep and not arguments.database:
        os.unlink(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
