#!/usr/bin/env python3
"""Score one actual, frozen empty-pool PG mapping for 04-1/R1 v2.

The program never simulates an unobserved layout and never invokes ceph, ssh,
or a network command.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from collections import Counter
from pathlib import Path


class EvidenceError(RuntimeError):
    pass


def load(path: Path):
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise EvidenceError(f"cannot parse {path}: {exc}") from exc


def pool_rows(data: dict) -> list[dict]:
    return data.get("pg_stats", data.get("pg_map", {}).get("pg_stats", []))


def normalize_mapping(row: dict) -> tuple[str, int, list[int], list[int]]:
    pgid = str(row.get("pgid", row.get("pg", "")))
    up = [int(x) for x in row.get("up", [])]
    acting = [int(x) for x in row.get("acting", up)]
    primary = row.get("primary", row.get("acting_primary", acting[0] if acting else None))
    if not pgid or primary is None or not up or not acting:
        raise EvidenceError(f"incomplete PG mapping row: {row!r}")
    return pgid, int(primary), up, acting


def metrics(rows: list[dict], expected_pg_num: int | None = None) -> dict:
    norm = [normalize_mapping(x) for x in rows]
    if expected_pg_num is not None and len(norm) != expected_pg_num:
        raise EvidenceError(f"PG count {len(norm)} != expected {expected_pg_num}")
    pgids = [x[0] for x in norm]
    if len(set(pgids)) != len(pgids):
        raise EvidenceError("duplicate PG id")
    osds = sorted({x for _, _, up, acting in norm for x in up + acting})
    if len(osds) != 6:
        raise EvidenceError(f"R1 contract requires exactly six OSDs, got {osds}")
    primary = Counter(x[1] for x in norm)
    if any(pri not in acting for _, pri, _, acting in norm):
        raise EvidenceError("primary is not a member of acting set")
    acting = Counter(o for x in norm for o in x[3])
    pvals = [primary[o] for o in osds]
    avals = [acting[o] for o in osds]
    mean = len(norm) / 6.0
    i_primary = max(pvals) / mean
    cv_primary = statistics.pstdev(pvals) / statistics.mean(pvals)
    all_six = all(len(set(x[3])) == 6 and set(x[3]) == set(osds) for x in norm)
    return {
        "pg_num": len(norm), "osds": osds,
        "primary_histogram": {str(o): primary[o] for o in osds},
        "acting_count": {str(o): acting[o] for o in osds},
        "I_primary": i_primary, "CV_primary": cv_primary,
        "all_acting_sets_cover_six_osds": all_six,
        "rows": [{"pgid": p, "primary": pri, "up": up, "acting": act}
                 for p, pri, up, act in norm],
    }


def next_pool_id(osd_dump: dict) -> int:
    pools = osd_dump.get("pools", [])
    ids = [int(x.get("pool", x.get("pool_id"))) for x in pools]
    if not ids:
        raise EvidenceError("osd dump contains no pool ids")
    explicit = osd_dump.get("pool_max")
    # Ceph pool_max is the largest allocated id, not a reusable search knob.
    candidate = max(ids) + 1
    if explicit is not None and int(explicit) > max(ids):
        candidate = int(explicit) + 1
    return candidate


def registered_pool_id(path: Path) -> int:
    """Read the pool id recorded after the one allowed empty-pool registration."""
    data = load(path)
    value = data.get("pool_id")
    if value is None:
        raise EvidenceError("registered map has no pool_id")
    return int(value)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--inventory", type=Path, required=True)
    ap.add_argument("--registered-map", type=Path,
                    help="post-registration frozen map; supersedes next-pool prediction")
    ap.add_argument("--actual-only", action="store_true",
                    help="score only the actual map just captured after a PG change")
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--expected-current-pgs", type=int, default=32)
    ap.add_argument("--expected-all-pgs", type=int, default=33)
    args = ap.parse_args()
    inv = args.inventory.resolve()
    if not inv.is_dir():
        raise EvidenceError("inventory directory missing")
    current_data = load(inv / "pg-single-pool.json")
    current = metrics(pool_rows(current_data), args.expected_current_pgs)
    all_data = load(inv / "pg-all-pools.json")
    all_count = len(pool_rows(all_data))
    if all_count != args.expected_all_pgs:
        raise EvidenceError(
            f"all-pool PG count {all_count} != expected {args.expected_all_pgs}")
    if args.registered_map:
        registered = args.registered_map.resolve()
        if not registered.is_file() or registered.is_symlink():
            raise EvidenceError("registered map missing or symlinked")
        expected_pool_id = registered_pool_id(registered)
        registered_data = load(registered)
        registered_rows = pool_rows(registered_data)
        registered_metrics = metrics(registered_rows, None if args.actual_only else 32)
    else:
        expected_pool_id = next_pool_id(load(inv / "osd-dump.json"))
        registered_metrics = None

    if args.actual_only:
        if not args.registered_map:
            raise EvidenceError("--actual-only requires --registered-map")
        actual = registered_metrics
        if actual["pg_num"] not in (32, 64, 128):
            raise EvidenceError(f"actual PG count is outside frozen ladder: {actual['pg_num']}")
        if any(int(row["pgid"].split(".", 1)[0]) != expected_pool_id
               for row in actual["rows"]):
            raise EvidenceError("registered map contains a foreign pool PG")
        actual["pool_id"] = expected_pool_id
        actual["source"] = str(registered)
        actual["eligible"] = (
            actual["I_primary"] <= 1.05 + 1e-12
            and current["I_primary"] - actual["I_primary"] >= 0.075 - 1e-12
            and actual["pg_num"] <= 128)
        verdict = "SELECTED" if actual["eligible"] else (
            "NEXT_REQUIRED" if actual["pg_num"] < 128 else "BLOCKED")
        result = {
            "schema": 2, "verdict": verdict,
            "reason": "actual registered-map measurement; no offline PG simulation",
            "single_pool_pg_count": current["pg_num"], "all_pool_pg_count": all_count,
            "registered_pool_id": expected_pool_id,
            "registered_map": str(registered), "registered": actual,
            "current": current, "candidates": [actual], "missing_candidate_files": [],
            "selected": actual if actual["eligible"] else None,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(f"VERDICT={verdict}")
        print(f"ACTUAL_PG_NUM={actual['pg_num']}")
        print(f"ACTUAL_I_PRIMARY={actual['I_primary']:.6f}")
        return 0

    raise EvidenceError("R1_REGISTERED_MAP_SIMULATION_INSUFFICIENT: actual-only mode is required; synthetic candidates are forbidden")


def plan_upmap(registered_map: Path, target: dict, output: Path) -> dict:
    """Compute minimal ceph osd pg-upmap commands to reach target primary distribution."""
    data = load(registered_map)
    rows_raw = pool_rows(data)
    if len(rows_raw) != 64:
        raise EvidenceError(f"plan-upmap requires 64 PG, got {len(rows_raw)}")
    pool_id = data.get("pool_id")
    if pool_id is None:
        raise EvidenceError("registered map has no pool_id")
    # Validate target
    if set(target.keys()) != {0, 1, 2, 3, 4, 5}:
        raise EvidenceError(f"target keys must be 0..5, got {sorted(target.keys())}")
    if sum(target.values()) != 64 or any(v < 0 for v in target.values()):
        raise EvidenceError(f"target sum must be 64 with no negatives, got sum={sum(target.values())}")
    # Validate each PG row
    seen_pgids = set()
    for r in rows_raw:
        pgid = str(r.get("pgid", ""))
        if not pgid:
            raise EvidenceError(f"PG row has no pgid: {r}")
        parts = pgid.split(".", 1)
        if len(parts) != 2 or parts[0] != str(pool_id):
            raise EvidenceError(f"PGID {pgid} prefix != pool_id {pool_id}")
        if not re.match(r'^[0-9a-f]+$', parts[1]):
            raise EvidenceError(f"PGID {pgid} suffix is not hex")
        if pgid in seen_pgids:
            raise EvidenceError(f"duplicate PGID {pgid}")
        seen_pgids.add(pgid)
        up = [int(x) for x in r.get("up", [])]
        acting = [int(x) for x in r.get("acting", up)]
        if not up or not acting:
            raise EvidenceError(f"PG {pgid} has empty up/acting")
        if set(up) != {0, 1, 2, 3, 4, 5} or set(acting) != {0, 1, 2, 3, 4, 5}:
            raise EvidenceError(f"PG {pgid} up/acting must be exactly OSD 0..5")
        if len(up) != 6 or len(acting) != 6:
            raise EvidenceError(f"PG {pgid} up/acting must have exactly 6 members")
        if up != acting:
            raise EvidenceError(f"PG {pgid} has existing override (up != acting); natural map required")
        primary = r.get("primary", r.get("acting_primary"))
        if primary is None:
            primary = acting[0]
        else:
            primary = int(primary)
        if primary != acting[0]:
            raise EvidenceError(f"PG {pgid} primary {primary} != acting[0] {acting[0]}")
        if primary not in acting:
            raise EvidenceError(f"PG {pgid} primary {primary} not in acting set")

    norm = [normalize_mapping(x) for x in rows_raw]
    osds = [0, 1, 2, 3, 4, 5]
    current = Counter(x[1] for x in norm)

    # Already at target?
    if all(current[o] == target[o] for o in osds):
        result = {
            "pool_id": pool_id, "pg_num": 64,
            "target_histogram": {str(o): target[o] for o in osds},
            "current_histogram": {str(o): current[o] for o in osds},
            "steered_histogram": {str(o): current[o] for o in osds},
            "upmap_count": 0, "upmap_commands": [], "rollback_commands": [],
            "I_primary_steered": max(current.values()) / (64 / 6),
        }
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        return result

    surplus, deficit = {}, {}
    for o in osds:
        diff = current[o] - target[o]
        if diff > 0: surplus[o] = diff
        elif diff < 0: deficit[o] = -diff

    upmaps, rollbacks = [], []
    for s_osd in sorted(surplus):
        for pgid, _, _, acting in [x for x in norm if x[1] == s_osd]:
            if surplus[s_osd] == 0:
                break
            for d_osd in sorted(deficit):
                if deficit[d_osd] > 0 and d_osd in acting:
                    new_acting = list(acting)
                    new_acting.remove(d_osd)
                    new_acting.insert(0, d_osd)
                    upmaps.append({
                        "pgid": pgid, "pool_id": pool_id,
                        "old_primary": s_osd, "new_primary": d_osd,
                        "old_acting": acting, "new_acting": new_acting,
                        "command": f"sudo ceph osd pg-upmap {pgid} {' '.join(map(str,new_acting))}",
                    })
                    rollbacks.append({
                        "pgid": pgid, "pool_id": pool_id,
                        "command": f"sudo ceph osd rm-pg-upmap {pgid}",
                    })
                    surplus[s_osd] -= 1
                    deficit[d_osd] -= 1
                    break

    if sum(surplus.values()) > 0 or sum(deficit.values()) > 0:
        raise EvidenceError(
            f"cannot reach target; remaining surplus={surplus} deficit={deficit}")

    steered = Counter(current)
    for u in upmaps:
        steered[u["old_primary"]] -= 1
        steered[u["new_primary"]] += 1

    # Verify upmap count equals total surplus
    total_surplus = sum(max(0, current[o] - target[o]) for o in osds)
    assert len(upmaps) == total_surplus, f"upmap count {len(upmaps)} != surplus {total_surplus}"

    # Verify each upmap: same member set, new primary is first
    for u in upmaps:
        assert set(u["old_acting"]) == set(u["new_acting"]), f"{u['pgid']}: acting members changed"
        assert u["new_acting"][0] == u["new_primary"], f"{u['pgid']}: primary not first"
        assert u["new_primary"] != u["old_primary"], f"{u['pgid']}: no-op upmap"

    result = {
        "pool_id": pool_id, "pg_num": 64,
        "target_histogram": {str(o): target[o] for o in osds},
        "current_histogram": {str(o): current[o] for o in osds},
        "steered_histogram": {str(o): steered[o] for o in osds},
        "upmap_count": len(upmaps),
        "upmap_commands": upmaps,
        "rollback_commands": rollbacks,
        "I_primary_steered": max(steered.values()) / (64 / 6),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def verify_steered(natural_map: Path, plan_path: Path, steered_map: Path, target: dict, output: Path) -> dict:
    """Verify steered map is consistent with natural map + upmap plan."""
    natural = load(natural_map)
    plan = load(plan_path)
    steered = load(steered_map)
    pool_id = natural.get("pool_id")
    if pool_id is None:
        raise EvidenceError("natural map has no pool_id")
    if plan.get("pool_id") != pool_id:
        raise EvidenceError(f"plan pool_id {plan.get('pool_id')} != natural {pool_id}")
    if steered.get("pool_id") != pool_id:
        raise EvidenceError(f"steered pool_id {steered.get('pool_id')} != natural {pool_id}")

    nat_rows = {str(r.get("pgid", "")): r for r in pool_rows(natural)}
    st_rows = {str(r.get("pgid", "")): r for r in pool_rows(steered)}
    if len(nat_rows) != 64 or len(st_rows) != 64:
        raise EvidenceError(f"need 64 PG in both maps: natural={len(nat_rows)} steered={len(st_rows)}")
    if set(nat_rows.keys()) != set(st_rows.keys()):
        raise EvidenceError("PGID sets differ between natural and steered")
    if len(set(nat_rows.keys())) != 64:
        raise EvidenceError("duplicate PGIDs in natural map")
    # Plan PGID uniqueness and count consistency
    plan_cmds = plan.get("upmap_commands", [])
    plan_rbks = plan.get("rollback_commands", [])
    plan_pgs_list = [str(u["pgid"]) for u in plan_cmds]
    if len(plan_pgs_list) != len(set(plan_pgs_list)):
        raise EvidenceError("duplicate PGIDs in plan upmap commands")
    if len(plan_cmds) != len(plan_rbks):
        raise EvidenceError(f"upmap count {len(plan_cmds)} != rollback count {len(plan_rbks)}")
    if plan.get("upmap_count") != len(plan_cmds):
        raise EvidenceError(f"upmap_count field {plan.get('upmap_count')} != actual {len(plan_cmds)}")
    plan_pgs = {str(u["pgid"]): u for u in plan_cmds}
    osds = [0, 1, 2, 3, 4, 5]

    for pgid in sorted(nat_rows):
        nat_r = nat_rows[pgid]
        st_r = st_rows[pgid]
        # State must be active+clean
        for label, r in [("natural", nat_r), ("steered", st_r)]:
            state = str(r.get("state", r.get("status", "")))
            if state and "active+clean" not in state:
                raise EvidenceError(f"PG {pgid} {label} state={state}, not active+clean")
        # Check up_primary/acting_primary/primary consistency
        for label, r in [("natural", nat_r), ("steered", st_r)]:
            up = [int(x) for x in r.get("up", [])]
            acting = [int(x) for x in r.get("acting", up)]
            if up != acting:
                raise EvidenceError(f"PG {pgid} {label} has up != acting")
            for pk in ("up_primary", "acting_primary", "primary"):
                if pk in r:
                    pv = int(r[pk])
                    if pv != acting[0]:
                        raise EvidenceError(f"PG {pgid} {label} {pk}={pv} != acting[0]={acting[0]}")
        nat = normalize_mapping(nat_r)
        st = normalize_mapping(st_r)
        # Acting set membership must not change
        if set(nat[3]) != set(st[3]):
            raise EvidenceError(f"PG {pgid} acting members changed: {nat[3]} -> {st[3]}")
        if set(nat[3]) != set(osds):
            raise EvidenceError(f"PG {pgid} acting != OSD 0..5")

        if pgid in plan_pgs:
            u = plan_pgs[pgid]
            # Steered acting/up must match plan's new_acting exactly
            st_up = [int(x) for x in st_r.get("up", [])]
            if st_up != u["new_acting"]:
                raise EvidenceError(f"PG {pgid} steered up {st_up} != plan new_acting {u['new_acting']}")
            if st[3] != u["new_acting"]:
                raise EvidenceError(f"PG {pgid} steered acting {st[3]} != plan {u['new_acting']}")
            # Old acting in plan must match natural
            if u["old_acting"] != nat[3]:
                raise EvidenceError(f"PG {pgid} plan old_acting {u['old_acting']} != natural {nat[3]}")
            # Primary must be new primary
            if st[1] != u["new_primary"]:
                raise EvidenceError(f"PG {pgid} steered primary {st[1]} != plan new_primary {u['new_primary']}")
            # Command string must contain full pgid and correct OSD order
            expected_cmd = f"sudo ceph osd pg-upmap {pgid} {' '.join(map(str, u['new_acting']))}"
            if u.get("command") != expected_cmd:
                raise EvidenceError(f"PG {pgid} command mismatch: {u.get('command')} != {expected_cmd}")
        else:
            # PG not in plan: must be completely unchanged (up==acting==natural)
            if st[3] != nat[3]:
                raise EvidenceError(f"PG {pgid} (not in plan) acting changed: {nat[3]} -> {st[3]}")
            if st[1] != nat[1]:
                raise EvidenceError(f"PG {pgid} (not in plan) primary changed: {nat[1]} -> {st[1]}")

    # Final histogram
    steered_prim = Counter(normalize_mapping(st_rows[pgid])[1] for pgid in nat_rows)
    actual = {o: steered_prim[o] for o in osds}
    if not all(actual[o] == target[o] for o in osds):
        raise EvidenceError(f"steered histogram {actual} != target {target}")

    i_primary = max(actual.values()) / (64 / 6)
    if i_primary > 1.05 + 1e-12:
        raise EvidenceError(f"I_primary {i_primary} > 1.05")

    result = {
        "pool_id": pool_id, "pg_num": 64,
        "verified": True,
        "steered_histogram": {str(o): actual[o] for o in osds},
        "I_primary": i_primary,
        "plan_upmap_count": len(plan_pgs),
        "unchanged_pgs": 64 - len(plan_pgs),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main_upmap() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--registered-map", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--target", type=str, default="0:10,1:11,2:11,3:10,4:11,5:11")
    args = ap.parse_args()
    target = {}
    for pair in args.target.split(","):
        k, v = pair.split(":")
        target[int(k)] = int(v)
    res = plan_upmap(args.registered_map, target, args.output)
    print(f"UPMAP_COUNT={res['upmap_count']}")
    print(f"I_PRIMARY_STEERED={res['I_primary_steered']:.6f}")
    print(f"STEERED_HISTOGRAM={res['steered_histogram']}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--plan-upmap-mode":
        sys.argv = [sys.argv[0]] + sys.argv[2:]
        try:
            raise SystemExit(main_upmap())
        except EvidenceError as exc:
            print(f"E_R1B_MAP\t{exc}", file=sys.stderr)
            raise SystemExit(42)
    if len(sys.argv) > 1 and sys.argv[1] == "--verify-steered-mode":
        sys.argv = [sys.argv[0]] + sys.argv[2:]
        ap = argparse.ArgumentParser()
        ap.add_argument("--natural-map", type=Path, required=True)
        ap.add_argument("--plan", type=Path, required=True)
        ap.add_argument("--steered-map", type=Path, required=True)
        ap.add_argument("--output", type=Path, required=True)
        ap.add_argument("--target", type=str, default="0:10,1:11,2:11,3:10,4:11,5:11")
        args = ap.parse_args()
        target = {}
        for pair in args.target.split(","):
            k, v = pair.split(":"); target[int(k)] = int(v)
        try:
            res = verify_steered(args.natural_map, args.plan, args.steered_map, target, args.output)
            print(f"VERIFY_STEERED_PASS I_primary={res['I_primary']:.6f}")
            raise SystemExit(0)
        except EvidenceError as exc:
            print(f"E_R1B_VERIFY\t{exc}", file=sys.stderr)
            raise SystemExit(42)
    try:
        raise SystemExit(main())
    except EvidenceError as exc:
        print(f"E_R1_MAP\t{exc}", file=sys.stderr)
        raise SystemExit(42)
