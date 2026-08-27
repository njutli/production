#!/usr/bin/env bash
# 03-21: read-only TiKV storage/topology inventory.  No fio, mount, restart or config write.
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
NODES=(10.20.1.150 10.20.1.151 10.20.1.152)
SSH_PASSWORD=${T63_SSH_PASSWORD:-Sunrise@801}
SSH=(sshpass -p "$SSH_PASSWORD" ssh
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o BatchMode=no
  -o ConnectTimeout=8
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2)

die() {
  printf 'E_T63\t%s\n' "$*" >&2
  exit 42
}

self_test() {
  local tool
  for tool in bash curl gzip python3 sha256sum tar sshpass ssh; do
    command -v "$tool" >/dev/null || die "missing local tool: $tool"
  done
  python3 -c 'import json; d=json.loads("{\"blockdevices\":[]}"); assert isinstance(d["blockdevices"], list)'
  printf '%s\n' 't63 read-only inventory self-test: PASS'
}

if [[ ${1:-} == --self-test ]]; then
  self_test
  exit 0
fi

RUN_ID=${1:-$(date +%Y%m%d-%H%M%S)}
[[ "$RUN_ID" =~ ^[0-9]{8}-[0-9]{6}$ ]] || die "RUN_ID must be YYYYMMDD-HHMMSS"
[[ ${T63_USER_AUTH:-} == 03-21-read-only-inventory ]] || die "set T63_USER_AUTH=03-21-read-only-inventory after user authorization"

BASE=/tmp/production
OUT="$BASE/opencode-t3.21-${RUN_ID}"
ARCHIVE="$BASE/opencode-t3.21-${RUN_ID}.tar.gz"
LOCK="$BASE/t63-03-21.lock"
TASK="$REPO_ROOT/doc/perf-tasks/03-21-tikv-storage-isolation-feasibility-inventory.md"

mkdir -p "$BASE"
[[ ! -e "$OUT" && ! -e "$ARCHIVE" ]] || die "output already exists for RUN_ID=$RUN_ID"
mkdir "$LOCK" 2>/dev/null || die "concurrent/stale lock exists: $LOCK"
cleanup_lock() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup_lock EXIT INT TERM

mkdir -p "$OUT"/{nodes,pd,provenance}
printf 'run_id=%s\nepoch=%s\nauthorization=%s\nmode=READ_ONLY\n' \
  "$RUN_ID" "$(date +%s)" "$T63_USER_AUTH" > "$OUT/run.txt"

cp "$0" "$OUT/provenance/t63-tikv-storage-topology-inventory.sh"
[[ -f "$TASK" ]] && cp "$TASK" "$OUT/provenance/" || true
[[ -f "$SCRIPT_DIR/t62-r2-offline-attribution.py" ]] && \
  cp "$SCRIPT_DIR/t62-r2-offline-attribution.py" "$OUT/provenance/"

if pgrep -ax fio > "$OUT/local-fio.txt"; then
  printf 'S00\tforeign fio exists on collector; no remote collection performed\n' > "$OUT/INVALID.txt"
  die "foreign fio exists on collector"
fi

ssh_text() {
  local node=$1 name=$2 command=$3 node_dir="$OUT/nodes/$1"
  mkdir -p "$node_dir"
  if ! "${SSH[@]}" "$node" "$command" > "$node_dir/$name" 2> "$node_dir/$name.stderr"; then
    printf 'S01\t%s\t%s\n' "$node" "$name" >> "$OUT/INVALID.txt"
    return 1
  fi
}

process_fingerprint_command='set -eu
pids=$(ps -eo pid=,comm= | awk '\''$2=="tikv-server"{print $1}'\'')
count=$(printf "%s\n" "$pids" | awk '\''NF{n++} END{print n+0}'\'')
[ "$count" -eq 1 ] || { echo "tikv_pid_count=$count"; exit 42; }
pid=$pids
start=$(sudo awk '\''{print $22}'\'' "/proc/$pid/stat")
exe=$(sudo readlink -f "/proc/$pid/exe")
md5=$(sudo md5sum "$exe" | awk '\''{print $1}'\'')
cmd=$(sudo cat "/proc/$pid/cmdline" | tr "\0" " ")
printf "pid=%s\nstarttime=%s\nexe=%s\nexe_md5=%s\ncmdline=%s\n" "$pid" "$start" "$exe" "$md5" "$cmd"'

system_command='set -u
printf "hostname="; hostname -f 2>/dev/null || hostname
printf "epoch="; date +%s
printf "kernel="; uname -a
printf "uptime="; cat /proc/uptime
printf "cmdline="; cat /proc/cmdline
printf "numa_nodes="; cat /sys/devices/system/node/online 2>/dev/null || true
printf "cpu_online="; cat /sys/devices/system/cpu/online
printf "memory="; awk '\''/^(MemTotal|MemAvailable|HugePages_Total|HugePages_Free):/{print}'\'' /proc/meminfo
printf "tikv_processes\n"; ps -eo pid,lstart,comm,args | awk '\''NR==1 || $4=="tikv-server" || /tikv-server/'\''
printf "nvme_pci\n"; lspci -Dnn 2>/dev/null | grep -Ei "non-volatile|nvme" || true'

storage_paths_command='set -u
for path in /mnt/jfs-tikv /mnt/jfs-tikv/tikv /mnt/jfs-tikv/tikv/raft-engine /mnt/jfs-tikv/tikv/wal; do
  printf "PATH\t%s\n" "$path"
  findmnt -T "$path" -o TARGET,SOURCE,FSTYPE,OPTIONS,MAJ:MIN -n 2>&1 || true
  df -B1 -T "$path" 2>&1 || true
  stat -f -c "fs_type=%T block_size=%S blocks=%b free=%f avail=%a" "$path" 2>&1 || true
done'

sysfs_command='set -u
for path in /sys/block/nvme*n1; do
  [ -e "$path" ] || continue
  dev=${path##*/}
  printf "DEVICE\t/dev/%s\n" "$dev"
  for field in device/model device/serial device/firmware_rev device/numa_node queue/logical_block_size queue/physical_block_size queue/nr_requests queue/read_ahead_kb queue/scheduler; do
    if [ -r "$path/$field" ]; then printf "%s=" "$field"; cat "$path/$field"; fi
  done
  printf "device_link="; readlink -f "$path/device" || true
done
printf "BY_ID\n"
find /dev/disk/by-id -maxdepth 1 -type l -name '\''*nvme*'\'' -printf '\''%f\t%l\n'\'' 2>/dev/null | sort || true'

nvme_command='set -u
if ! command -v nvme >/dev/null; then echo NVME_CLI_MISSING; exit 0; fi
sudo nvme list -o json 2>&1 || true
for dev in /dev/nvme*n1; do
  [ -b "$dev" ] || continue
  printf "SMART\t%s\n" "$dev"
  sudo nvme smart-log "$dev" -o json 2>&1 || true
  printf "ID_CTRL\t%s\n" "$dev"
  sudo nvme id-ctrl "$dev" -o json 2>&1 || true
  printf "ID_NS\t%s\n" "$dev"
  sudo nvme id-ns "$dev" -o json 2>&1 || true
done'

for node in "${NODES[@]}"; do
  mkdir -p "$OUT/nodes/$node"
  if "${SSH[@]}" "$node" 'pgrep -ax fio' > "$OUT/nodes/$node/foreign-fio.txt" 2> "$OUT/nodes/$node/foreign-fio.txt.stderr"; then
    printf 'S00\t%s\tforeign fio exists; collection stopped\n' "$node" > "$OUT/INVALID.txt"
    die "foreign fio exists on $node"
  fi
  : > "$OUT/nodes/$node/foreign-fio.txt"

  ssh_text "$node" process-pre.txt "$process_fingerprint_command" || true
  ssh_text "$node" system.txt "$system_command" || true
  ssh_text "$node" lsblk.json 'lsblk -b -J -O' || true
  ssh_text "$node" findmnt.json 'findmnt -J -o TARGET,SOURCE,FSTYPE,OPTIONS,FSROOT,MAJ:MIN' || true
  ssh_text "$node" df.txt 'df -B1 -T' || true
  ssh_text "$node" blkid.txt 'sudo blkid' || true
  ssh_text "$node" storage-paths.txt "$storage_paths_command" || true
  ssh_text "$node" nvme-sysfs.txt "$sysfs_command" || true
  ssh_text "$node" nvme-cli.txt "$nvme_command" || true
  ssh_text "$node" lspci-vv.txt 'sudo lspci -Dvv 2>/dev/null | awk '\''BEGIN{RS="";IGNORECASE=1} /non-volatile|nvme/{print $0"\n"}'\''' || true

  if ! curl -fsS --connect-timeout 3 --max-time 10 "http://$node:20180/config" \
      > "$OUT/nodes/$node/tikv-config-pre.json"; then
    printf 'S01\t%s\ttikv-config-pre\n' "$node" >> "$OUT/INVALID.txt"
  fi
  if ! curl -fsS --connect-timeout 3 --max-time 15 "http://$node:20180/metrics" \
      | gzip > "$OUT/nodes/$node/tikv-metrics.prom.gz"; then
    printf 'S01\t%s\ttikv-metrics\n' "$node" >> "$OUT/INVALID.txt"
  fi
done

pd_capture() {
  local endpoint=$1 name=$2 node
  for node in "${NODES[@]}"; do
    if curl -fsS --connect-timeout 3 --max-time 15 "http://$node:2379$endpoint" \
        > "$OUT/pd/$name.tmp" 2> "$OUT/pd/$name.stderr"; then
      mv "$OUT/pd/$name.tmp" "$OUT/pd/$name"
      printf '%s\n' "$node" > "$OUT/pd/$name.source"
      return 0
    fi
  done
  rm -f "$OUT/pd/$name.tmp"
  return 1
}

pd_capture /pd/api/v1/health health.json || printf 'S01\tpd-health\n' >> "$OUT/INVALID.txt"
pd_capture /pd/api/v1/stores stores.json || printf 'S01\tpd-stores\n' >> "$OUT/INVALID.txt"
pd_capture /pd/api/v1/config config.json || printf 'S01\tpd-config\n' >> "$OUT/INVALID.txt"
pd_capture /pd/api/v1/hotspot/stores hotspot-stores.json || true
pd_capture /pd/api/v1/hotspot/regions/write hotspot-regions-write.json || true

for node in "${NODES[@]}"; do
  if ! curl -fsS --connect-timeout 3 --max-time 10 "http://$node:20180/config" \
      > "$OUT/nodes/$node/tikv-config-post.json"; then
    printf 'S02\t%s\ttikv-config-post\n' "$node" >> "$OUT/INVALID.txt"
  fi
  ssh_text "$node" process-post.txt "$process_fingerprint_command" || true
done

python3 - "$OUT" "${NODES[@]}" <<'PY'
import gzip
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
nodes = sys.argv[2:]
errors = []
for node in nodes:
    base = root / "nodes" / node
    for name in ("lsblk.json", "findmnt.json", "tikv-config-pre.json", "tikv-config-post.json"):
        try:
            json.loads((base / name).read_text())
        except Exception as exc:
            errors.append(f"S03\t{node}\t{name}\t{exc}")
    try:
        with gzip.open(base / "tikv-metrics.prom.gz", "rt") as stream:
            first = stream.readline()
        if not first:
            raise ValueError("empty metrics")
    except Exception as exc:
        errors.append(f"S03\t{node}\ttikv-metrics.prom.gz\t{exc}")
    try:
        pre = (base / "process-pre.txt").read_bytes()
        post = (base / "process-post.txt").read_bytes()
        if pre != post:
            errors.append(f"S02\t{node}\tTiKV PID/start/exe/cmdline changed")
    except Exception as exc:
        errors.append(f"S03\t{node}\tprocess fingerprint\t{exc}")
    try:
        if (base / "tikv-config-pre.json").read_bytes() != (base / "tikv-config-post.json").read_bytes():
            errors.append(f"S02\t{node}\tTiKV config changed")
    except Exception as exc:
        errors.append(f"S03\t{node}\tconfig comparison\t{exc}")

for name in ("health.json", "stores.json", "config.json"):
    try:
        json.loads((root / "pd" / name).read_text())
    except Exception as exc:
        errors.append(f"S03\tpd\t{name}\t{exc}")

if errors:
    with (root / "INVALID.txt").open("a") as stream:
        stream.write("\n".join(errors) + "\n")
PY

if [[ -f "$OUT/INVALID.txt" ]]; then
  printf 'result=INVENTORY_INCOMPLETE\n' > "$OUT/result.txt"
else
  printf 'result=COLLECTION_COMPLETE_ANALYSIS_PENDING\n' > "$OUT/result.txt"
fi

(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
tar -C "$BASE" -czf "$ARCHIVE" "${OUT##*/}"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

trap - EXIT INT TERM
cleanup_lock
printf 'ARCHIVE=%s\n' "$ARCHIVE"
if [[ -f "$OUT/INVALID.txt" ]]; then
  exit 9
fi
