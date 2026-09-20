#!/usr/bin/env python3
import argparse
import json
import re
import statistics
from pathlib import Path


def blocks(text: str):
    return [x for x in re.split(r"\n(?=goroutine \d+ \[)", text) if x.startswith("goroutine ")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root
    dumps = sorted((root / "goroutine-dumps").glob("*.txt"))
    if len(dumps) != 36:
        raise SystemExit(f"expected 36 dumps, got {len(dumps)}")

    rows = []
    for path in dumps:
        gs = blocks(path.read_text(errors="replace"))
        read_flush = [g for g in gs if "pkg/vfs.(*VFS).Read" in g and "pkg/vfs.(*fileWriter).Flush" in g]
        rows.append(
            {
                "dump": path.name,
                "goroutines": len(gs),
                "vfs_read": sum("pkg/vfs.(*VFS).Read" in g for g in gs),
                "read_in_filewriter_flush": len(read_flush),
                "read_flush_waitcond": sum("pkg/utils.(*Cond).WaitWithTimeout" in g for g in read_flush),
                "read_flush_semacquire": sum("[semacquire]" in g for g in read_flush),
                "read_flush_select": sum("[select]" in g for g in read_flush),
                "flush_helper_goroutines": sum("pkg/vfs.(*fileWriter).flush.gowrap" in g for g in gs),
                "commit_threads": sum("pkg/vfs.(*fileWriter).commitThread" in g for g in gs),
            }
        )

    keys = [x for x in rows[0] if x != "dump"]
    with (root / "goroutine-signal.tsv").open("w") as out:
        out.write("dump\t" + "\t".join(keys) + "\n")
        for row in rows:
            out.write(row["dump"] + "\t" + "\t".join(str(row[k]) for k in keys) + "\n")

    fio = json.loads((root / "formal" / "fio.json").read_text())
    job = fio["jobs"][0]
    summary = {
        "schema": 1,
        "dump_count": len(rows),
        "snapshots_with_read_flush": sum(r["read_in_filewriter_flush"] > 0 for r in rows),
        "metrics": {},
        "fio": {},
    }
    signal_snapshots = [r for r in rows if r["read_in_filewriter_flush"] > 0]
    active_snapshots = [r for r in rows if r["vfs_read"] >= 64]
    summary["signal_snapshot_fraction"] = len(signal_snapshots) / len(rows)
    summary["active_snapshot_count"] = len(active_snapshots)
    summary["active_snapshots_with_signal"] = sum(r["read_in_filewriter_flush"] > 0 for r in active_snapshots)
    summary["read_flush_occupancy_ratio"] = {
        "median": statistics.median(r["read_in_filewriter_flush"] / r["vfs_read"] for r in active_snapshots),
        "mean": statistics.fmean(r["read_in_filewriter_flush"] / r["vfs_read"] for r in active_snapshots),
        "max": max(r["read_in_filewriter_flush"] / r["vfs_read"] for r in active_snapshots),
        "note": "repeated-stack occupancy only; not an Amdahl time fraction",
    }
    for key in keys:
        values = [r[key] for r in rows]
        summary["metrics"][key] = {
            "min": min(values),
            "median": statistics.median(values),
            "mean": statistics.fmean(values),
            "max": max(values),
            "sum": sum(values),
        }
    for direction in ("read", "write"):
        item = job[direction]
        summary["fio"][direction] = {
            "bw_bytes_per_sec": item["bw_bytes"],
            "bw_MiB_per_sec": item["bw_bytes"] / 1048576,
            "iops": item["iops"],
            "clat_mean_ns": item["clat_ns"]["mean"],
            "clat_p99_ns": item["clat_ns"]["percentile"]["99.000000"],
        }
    summary["gate2a_signal"] = (
        "MATERIAL_SIGNAL"
        if summary["signal_snapshot_fraction"] >= 0.5
        and summary["metrics"]["read_in_filewriter_flush"]["median"] > 0
        else "NO_MATERIAL_SIGNAL"
    )
    (root / "gate2a-signal-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
