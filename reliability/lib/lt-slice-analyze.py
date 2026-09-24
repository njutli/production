#!/usr/bin/env python3
"""Offline raw/current slice accounting for one scoped JuiceFS metadata dump."""
from __future__ import annotations

import collections
import gzip
import json
import random
import sys


def visible(slices: list[dict], limit: int) -> tuple[dict[int, int], int]:
    covered: list[tuple[int, int]] = []
    ids: dict[int, int] = {}
    occupied = 0
    for item in reversed(slices):
        lo = max(0, item.get("pos", 0))
        hi = min(limit, item.get("pos", 0) + item["len"])
        if hi <= lo:
            continue
        overlap = sum(max(0, min(hi, right) - max(lo, left)) for left, right in covered)
        fresh = hi - lo - overlap
        if fresh and item["id"]:
            ids[item["id"]] = item["size"]
        if not fresh:
            continue
        occupied += fresh
        merged = []
        for left, right in covered:
            if right < lo:
                merged.append((left, right))
            elif hi < left:
                merged.append((lo, hi)); lo, hi = left, right
            else:
                lo, hi = min(lo, left), max(hi, right)
        merged.append((lo, hi)); covered = merged
        if occupied == limit:
            break
    return ids, occupied


def analyze(source: str) -> dict:
    data = json.load(gzip.open(source, "rt"))
    rows, all_raw, all_visible = [], {}, {}
    histogram = collections.Counter()

    def walk(entry: dict, path: str) -> None:
        if entry["attr"]["type"] == "regular":
            raw, live, count, coverage, lengths = {}, {}, 0, 0, []
            for chunk in entry.get("chunks", []):
                slices = chunk["slices"]
                lengths.append(len(slices)); histogram[len(slices)] += 1; count += len(slices)
                for item in slices:
                    if item["id"]:
                        if "off" in item:
                            assert item["off"] + item["len"] <= item["size"]
                        else:
                            assert item["len"] <= item["size"]
                        if item["id"] in raw:
                            assert raw[item["id"]] == item["size"]
                        raw[item["id"]] = item["size"]
                limit = min(64 * 2**20, max(0, entry["attr"]["length"] - chunk["index"] * 64 * 2**20))
                latest, covered = visible(slices, limit)
                live.update(latest); coverage += covered
            all_raw.update(raw); all_visible.update(live)
            rows.append({"path": path, "inode": entry["attr"]["inode"],
                         "logical_bytes": entry["attr"]["length"], "raw_records": count,
                         "unique_raw_slices": len(raw), "raw_full_slice_bytes": sum(raw.values()),
                         "visible_slices": len(live), "visible_full_slice_bytes": sum(live.values()),
                         "covered_logical_bytes": coverage,
                         "max_raw_records_per_chunk": max(lengths, default=0), "chunks": len(lengths)})
        for name, child in entry.get("entries", {}).items():
            walk(child, path + "/" + name)

    walk(data["FSTree"], "")
    if not rows:
        raise ValueError("no regular files in scoped dump")
    raw_bytes = sum(all_raw.values()); logical = sum(row["logical_bytes"] for row in rows)
    return {"files": len(rows), "logical_bytes": logical,
            "raw_records": sum(row["raw_records"] for row in rows),
            "unique_raw_slices": len(all_raw), "raw_full_slice_bytes": raw_bytes,
            "raw_object_count_at_B256": sum((size + 262143) // 262144 for size in all_raw.values()),
            "visible_unique_slices": len(all_visible),
            "visible_full_slice_bytes": sum(all_visible.values()),
            "fully_shadowed_unique_slices": len(all_raw.keys() - all_visible.keys()),
            "fully_shadowed_full_slice_bytes": sum(size for ident, size in all_raw.items() if ident not in all_visible),
            "raw_full_slice_amplification": raw_bytes / logical if logical else None,
            "chunk_record_histogram": dict(sorted(histogram.items())), "per_file": rows,
            "scope_caution": "latest-wins is reconstructed only inside this dump; other-subtree references are not excluded"}


def self_test() -> None:
    slices = [{"id": 1, "size": 64, "pos": 0, "len": 64}, {"id": 2, "size": 64, "pos": 0, "len": 64}]
    assert visible(slices, 64) == ({2: 64}, 64)
    slices[-1] = {"id": 2, "size": 16, "pos": 16, "len": 16}
    assert visible(slices, 64) == ({2: 16, 1: 64}, 64)
    rng = random.Random(5303)
    for _ in range(500):
        records, model, sizes = [], [None] * 64, {}
        for ident in range(1, rng.randrange(2, 80)):
            pos = rng.randrange(64); length = rng.randrange(1, 65 - pos)
            records.append({"id": ident, "size": length, "pos": pos, "len": length})
            sizes[ident] = length; model[pos:pos + length] = [ident] * length
        expected = {ident: sizes[ident] for ident in model if ident is not None}
        assert visible(records, 64) == (expected, sum(ident is not None for ident in model))
    print("LT_SLICE_ANALYZE_SELF_TEST_PASS")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    elif len(sys.argv) == 2:
        print(json.dumps(analyze(sys.argv[1]), indent=2))
    else:
        raise SystemExit("usage: lt-slice-analyze.py DUMP.json.gz | --self-test")
