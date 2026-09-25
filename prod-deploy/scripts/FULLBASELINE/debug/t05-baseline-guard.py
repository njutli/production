#!/usr/bin/env python3
"""Read-only 05-3b configuration and JuiceFS worker identity guard.

The guard deliberately inspects the *child* JuiceFS process which belongs to
the daemon-parent/worker pair.  A matching command line alone is not enough:
the child must have the requested CEPH_CONF, executable identity, and exactly
eight ``msgr-worker`` tasks.  ``--proc-root`` exists for the offline fixture
tests; the default is the live /proc filesystem.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


FROZEN_CONFIG_SHA256 = "c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48"
FROZEN_JUICEFS_MD5 = "24fae0852051c80ca571cb2f20275d46"
EXPECTED_MS_ASYNC_OP_THREADS = 8
MSGR_WORKER_RE = re.compile(r"^msgr-worker(?:-[0-9]+)?$")


class GuardError(RuntimeError):
    """A failed non-performance identity gate."""


def _regular_file(path: Path, label: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise GuardError(f"{label}_unreadable:{path}:{exc.strerror}") from exc
    if stat.S_ISLNK(info.st_mode):
        raise GuardError(f"{label}_symlink:{path}")
    if not stat.S_ISREG(info.st_mode):
        raise GuardError(f"{label}_not_regular:{path}")


def validate_config(path: Path, expected_sha256: str = FROZEN_CONFIG_SHA256,
                    expected_threads: int = EXPECTED_MS_ASYNC_OP_THREADS) -> dict[str, str]:
    """Validate the frozen config and the effective client thread value.

    The hash protects the complete private config.  Parsing the client value
    separately catches an accidentally supplied system/default config even in
    a test fixture where the expected hash is intentionally overridden.
    """

    _regular_file(path, "ceph_conf")
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected_sha256.lower():
        raise GuardError(f"ceph_conf_sha256:{digest}:expected:{expected_sha256}")

    section = None
    values: list[int] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        match = re.fullmatch(r"\[([^]]+)\]", line)
        if match:
            section = match.group(1).strip().lower()
            continue
        if "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key.lower() != "ms_async_op_threads" or section != "client":
            continue
        value = value.split("#", 1)[0].split(";", 1)[0].strip()
        if not re.fullmatch(r"[0-9]+", value):
            raise GuardError(f"ceph_conf_invalid_ms_async:{path}:{lineno}")
        values.append(int(value))
    if values != [expected_threads]:
        raise GuardError(f"ceph_conf_ms_async:{values}:expected:[{expected_threads}]")
    return {"ceph_conf": str(path), "ceph_conf_sha256": digest,
            "ms_async_op_threads": str(expected_threads)}


def _read_cmdline(path: Path) -> str:
    raw = path.read_bytes()
    return raw.replace(b"\0", b" ").decode("utf-8", errors="replace").strip()


def _has_token_sequence(cmdline: str, required: str) -> bool:
    """Match flattened argv by whole tokens, including multi-token options."""
    actual = cmdline.split()
    wanted = required.split()
    return bool(wanted) and any(actual[pos:pos + len(wanted)] == wanted
                                for pos in range(len(actual) - len(wanted) + 1))


def _read_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for item in path.read_bytes().split(b"\0"):
        if b"=" not in item:
            continue
        key, value = item.split(b"=", 1)
        env[key.decode(errors="replace")] = value.decode(errors="replace")
    return env


def _parse_stat(path: Path) -> tuple[int, int]:
    # comm may contain spaces; split only after its final closing parenthesis.
    text = path.read_text(encoding="utf-8", errors="replace")
    close = text.rfind(")")
    if close < 0:
        raise GuardError(f"proc_stat_invalid:{path}")
    fields = text[close + 2 :].split()
    try:
        return int(fields[1]), int(fields[19])  # ppid and field 22 starttime
    except (IndexError, ValueError) as exc:
        raise GuardError(f"proc_stat_invalid:{path}") from exc


def _proc_exe(path: Path) -> str:
    """Read a real /proc exe symlink, while accepting fixture symlinks."""
    try:
        return os.path.realpath(path / "exe")
    except OSError as exc:
        raise GuardError(f"proc_exe_unreadable:{path}:{exc.strerror}") from exc


def _md5(path: Path) -> str:
    digest = hashlib.md5(usedforsecurity=False)
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    starttime: int
    exe: str
    exe_md5: str
    ceph_conf: str
    cmdline: str
    msgr_workers: int


def _processes(proc_root: Path, expected_exe: Path, expected_md5: str,
               required_tokens: Iterable[str]) -> list[Process]:
    expected_exe_real = os.path.realpath(expected_exe)
    required = tuple(required_tokens)
    rows: list[Process] = []
    try:
        entries = sorted((x for x in proc_root.iterdir() if x.name.isdigit()), key=lambda x: int(x.name))
    except OSError as exc:
        raise GuardError(f"proc_root_unreadable:{proc_root}:{exc.strerror}") from exc
    for pdir in entries:
        try:
            pid = int(pdir.name)
            exe = _proc_exe(pdir)
            if exe != expected_exe_real:
                continue
            cmdline = _read_cmdline(pdir / "cmdline")
            if any(not _has_token_sequence(cmdline, token) for token in required):
                continue
            ppid, starttime = _parse_stat(pdir / "stat")
            env = _read_env(pdir / "environ")
            conf = env.get("CEPH_CONF", "")
            # Do not use a parent's command line as a substitute for the env.
            # The final selected child is checked again below.
            # Hash the proc link itself.  This reads the executable attached to
            # this PID, rather than a later pathname which may have been
            # replaced after the process was selected.
            md5 = _md5(pdir / "exe")
            if _proc_exe(pdir) != exe:
                raise GuardError(f"proc_exe_changed:{pid}")
            if md5 != expected_md5.lower():
                continue
            workers = 0
            for task in (pdir / "task").iterdir():
                if not task.is_dir():
                    continue
                try:
                    if MSGR_WORKER_RE.fullmatch((task / "comm").read_text(
                            encoding="utf-8", errors="replace").strip()):
                        workers += 1
                except OSError:
                    continue
            ppid_after, starttime_after = _parse_stat(pdir / "stat")
            if (ppid, starttime) != (ppid_after, starttime_after):
                raise GuardError(f"proc_stat_changed:{pid}")
            rows.append(Process(pid, ppid, starttime, exe, md5, conf, cmdline, workers))
        except (GuardError, OSError, ValueError):
            # A process can disappear during a live scan.  It is evidence
            # failure, not a reason to trust another less-specific process.
            continue
    return rows


def check_worker(config: Path, juicefs_exe: Path, proc_root: Path = Path("/proc"),
                 expected_config_sha256: str = FROZEN_CONFIG_SHA256,
                 expected_exe_md5: str = FROZEN_JUICEFS_MD5,
                 required_tokens: Iterable[str] = (), pid: int | None = None) -> Process:
    config_real = os.path.abspath(config)
    validate_config(config, expected_config_sha256)
    _regular_file(juicefs_exe, "juicefs_exe")
    actual_exe_md5 = _md5(juicefs_exe)
    if actual_exe_md5 != expected_exe_md5.lower():
        raise GuardError(f"juicefs_exe_md5:{actual_exe_md5}:expected:{expected_exe_md5}")

    # Discover the complete same-binary process set first.  A daemon parent
    # can expose a flattened or otherwise different argv, so scope tokens are
    # applied only to the prospective child, never to parent discovery.
    rows = _processes(proc_root, juicefs_exe, expected_exe_md5, ())
    row_by_pid = {row.pid: row for row in rows}
    # A daemon-parent can have the right binary, args and even eight threads.
    # Only a matching child process is accepted as the service worker.
    required = tuple(required_tokens)
    selected = [row for row in rows
                if row.ceph_conf == config_real
                and row.ppid in row_by_pid
                and all(_has_token_sequence(row.cmdline, token) for token in required)]
    if pid is not None:
        selected = [row for row in selected if row.pid == pid]
    if len(selected) != 1:
        if not selected:
            raise GuardError("juicefs_worker_missing_or_parent_only")
        raise GuardError(f"juicefs_worker_ambiguous:{[row.pid for row in selected]}")
    worker = selected[0]
    if worker.msgr_workers != EXPECTED_MS_ASYNC_OP_THREADS:
        raise GuardError(f"msgr_worker_threads:{worker.msgr_workers}:expected:{EXPECTED_MS_ASYNC_OP_THREADS}")
    return worker


def _safe_tsv(value: str) -> str:
    return value.replace("\t", " ").replace("\n", " ")


def write_evidence(worker: Process, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise GuardError(f"evidence_output_exists:{output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    fields = ("pid", "ppid", "starttime_ticks", "exe", "exe_md5", "ceph_conf",
              "msgr_worker_threads", "cmdline")
    values = (worker.pid, worker.ppid, worker.starttime, worker.exe, worker.exe_md5,
              worker.ceph_conf, worker.msgr_workers, worker.cmdline)
    output.write_text("\t".join(fields) + "\n" + "\t".join(_safe_tsv(str(x)) for x in values) + "\n",
                      encoding="utf-8")


def _fixture_stat(pid: int, ppid: int, starttime: int) -> str:
    fields = ["S", str(ppid)] + ["0"] * 20
    fields[19] = str(starttime)
    return f"{pid} (juicefs mount) " + " ".join(fields) + "\n"


def _fixture_process(root: Path, pid: int, ppid: int, exe: Path, config: Path,
                     threads: int, command: bytes | None = None,
                     numbered_threads: bool = False) -> None:
    pdir = root / str(pid)
    (pdir / "task").mkdir(parents=True)
    (pdir / "exe").symlink_to(exe)
    (pdir / "cmdline").write_bytes(command or b"juicefs mount -d --cache-size 0 /tmp/jfs-05-3b")
    (pdir / "environ").write_bytes(f"CEPH_CONF={config}\0PATH=/usr/bin\0".encode())
    (pdir / "stat").write_text(_fixture_stat(pid, ppid, 1000 + pid))
    for index in range(threads):
        task = pdir / "task" / str(pid + index + 1)
        task.mkdir()
        name = f"msgr-worker-{index}" if numbered_threads else "msgr-worker"
        (task / "comm").write_text(name + "\n")


def self_test() -> dict[str, str]:
    """Exercise the four required offline fixtures without touching live /proc."""
    with tempfile.TemporaryDirectory(prefix="t05-baseline-guard-") as temporary:
        root = Path(temporary)
        proc = root / "proc"
        proc.mkdir()
        config = root / "ceph-msgr8.conf"
        config.write_text("[global]\nfsid = f8137e5a-8af2-11f1-aa1c-4df480fc234d\n\n[client]\n\tms_async_op_threads = 8\n")
        config3 = root / "ceph-msgr3.conf"
        config3.write_text(config.read_text().replace("= 8", "= 3"))
        exe = root / "juicefs"
        exe.write_bytes(b"fixture-juicefs-worker\n")
        expected_sha = hashlib.sha256(config.read_bytes()).hexdigest()
        expected_md5 = _md5(exe)
        tokens = ("--cache-size 0", "/tmp/jfs-05-3b")

        # Correct daemon-parent/worker pair: only the child is accepted.
        # Parent argv is intentionally flattened/different; only child scope
        # tokens are required for selecting the actual worker.
        _fixture_process(proc, 300, 1, exe, config, 1, b"juicefs mount -d")
        _fixture_process(proc, 301, 300, exe, config, 8, numbered_threads=True)
        worker = check_worker(config, exe, proc, expected_sha, expected_md5, tokens)
        assert worker.pid == 301 and worker.msgr_workers == 8
        assert check_worker(config, exe, proc, expected_sha, expected_md5, tokens, pid=301).pid == 301
        correct = "PASS"

        # A daemon-parent with eight similarly named threads is not a worker.
        wrong = root / "wrongparent"
        wrong.mkdir()
        _fixture_process(wrong, 400, 1, exe, config, 8)
        try:
            check_worker(config, exe, wrong, expected_sha, expected_md5, tokens)
        except GuardError as exc:
            assert str(exc) == "juicefs_worker_missing_or_parent_only"
            wrong_parent = "PASS"
        else:
            raise AssertionError("wrongparent fixture unexpectedly passed")

        # Parent exists, but no child carries the launch-scoped CEPH_CONF.
        missing = root / "worker-missing"
        missing.mkdir()
        _fixture_process(missing, 500, 1, exe, config, 1)
        _fixture_process(missing, 501, 500, exe, config3, 8)
        try:
            check_worker(config, exe, missing, expected_sha, expected_md5, tokens)
        except GuardError as exc:
            assert str(exc) == "juicefs_worker_missing_or_parent_only"
            worker_missing = "PASS"
        else:
            raise AssertionError("worker-missing fixture unexpectedly passed")

        # A similarly named mount must not satisfy a scoped token.
        bounded = root / "bounded-scope"
        bounded.mkdir()
        _fixture_process(bounded, 600, 1, exe, config, 1)
        _fixture_process(bounded, 601, 600, exe, config, 8,
                         b"juicefs mount -d --cache-size 0 /tmp/jfs-05-3b-other",
                         numbered_threads=True)
        try:
            check_worker(config, exe, bounded, expected_sha, expected_md5, tokens)
        except GuardError as exc:
            assert str(exc) == "juicefs_worker_missing_or_parent_only"
            bounded_scope = "PASS"
        else:
            raise AssertionError("bounded scope fixture unexpectedly passed")

        try:
            check_worker(config3, exe, proc, expected_sha, expected_md5, tokens)
        except GuardError as exc:
            assert str(exc).startswith("ceph_conf_sha256:")
            config_three = "PASS"
        else:
            raise AssertionError("config3 fixture unexpectedly passed")
    return {"config3": config_three, "wrongparent": wrong_parent,
            "worker_missing": worker_missing, "bounded_scope": bounded_scope,
            "eight_threads": correct}


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--juicefs-exe", type=Path, required=True)
    parser.add_argument("--proc-root", type=Path, default=Path("/proc"))
    parser.add_argument("--require-token", action="append", default=[])
    parser.add_argument("--pid", type=int)
    parser.add_argument("--output", type=Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = os.sys.argv[1:]
    if argv == ["self-test"]:
        result = self_test()
        print("T05_BASELINE_GUARD_SELF_TEST_PASS\t" + "\t".join(f"{k}={v}" for k, v in result.items()))
        return 0
    try:
        args = _parser().parse_args(argv)
        worker = check_worker(args.config, args.juicefs_exe, args.proc_root,
                              FROZEN_CONFIG_SHA256, FROZEN_JUICEFS_MD5,
                              args.require_token, args.pid)
        if args.output:
            write_evidence(worker, args.output)
        print("T05_BASELINE_GUARD_PASS\tpid=%s\tstarttime=%s\tmsgr_worker_threads=%s" %
              (worker.pid, worker.starttime, worker.msgr_workers))
        return 0
    except (GuardError, OSError, ValueError) as exc:
        print(f"T05_BASELINE_GUARD_FAIL\t{exc}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
