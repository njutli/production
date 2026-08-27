#!/usr/bin/env bash
# 157-side Phase-I read-only inventory. It performs no remote file upload or mutation.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/t65-common.sh"

RUN_ID=${1:-}
t65_check_run_id "$RUN_ID"
t65_make_ssh_array
t65_require_tools sshpass ssh sha256sum awk python3
OUT="/tmp/production/opencode-t3.22b-${RUN_ID}/inventory"
[[ ! -e "$OUT/INVENTORY_PASS" ]] || t65_die 'inventory already completed for this RUN_ID'
mkdir -p "$OUT/nodes"

remote_inventory() {
  local node=$1
  "${T65_SSH[@]}" "$node" bash -s -- "$node" <<'REMOTE'
set -euo pipefail
export LC_ALL=C
expected=$1
actual=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^10\.20\.1\./{print;exit}')
[[ "$actual" == "$expected" ]] || { echo "HOST_MISMATCH expected=$expected actual=${actual:-unknown}" >&2; exit 42; }
printf 'section\thost\nnode\t%s\nhostname\t%s\nuid\t%s\ngid\t%s\n' "$expected" "$(hostname -f 2>/dev/null || hostname)" "$(id -u)" "$(id -g)"
awk '/^(MemTotal|MemAvailable):/{print "mem\t"$1"\t"$2}' /proc/meminfo
printf 'section\tproduction-units\n'
for unit in pd tikv; do
  printf 'unit\t%s\t%s\t%s\t%s\t%s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)" \
    "$(systemctl show "$unit" -p MainPID --value)" "$(systemctl show "$unit" -p FragmentPath --value)" "$(systemctl show "$unit" -p ExecStart --value)"
done
for svc in pd-server tikv-server; do
  ps -eo pid=,comm= | awk -v s="$svc" '$2==s{print $1}' | while read -r pid; do
    printf 'process\t%s\t%s\t%s\t%s\t%s\n' "$svc" "$pid" "$(awk '{print $22}' /proc/$pid/stat)" "$(readlink -f /proc/$pid/exe)" "$(tr '\0' ' ' < /proc/$pid/cmdline)"
  done
done
printf 'section\tproduction-files\n'
for f in /opt/pd/conf/pd.toml /opt/tikv/conf/tikv.toml; do
  [[ -f "$f" ]] && printf 'sha256\t%s\t%s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
done
printf 'section\tmount-capacity\n'
findmnt -rn -M /mnt/jfs-tikv -o SOURCE,TARGET,FSTYPE,OPTIONS,UUID
df -B1 -T /mnt/jfs-tikv
lsblk -b -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,PKNAME,MODEL,SERIAL
printf 'section\tports\n'
for port in 2379 2380 20160 20180 12379 12380 30160 30180; do ss -Hlnpt "sport = :$port" || true; done
printf 'section\tt65-residue\n'
findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS | awk '$2 ~ /^\/mnt\/jfs-t6[45]-/{print}'
sudo losetup -l -n -O NAME,BACK-FILE | awk '$2 ~ /\/jfs-t6[45]-/{print}'
# All t64/t65 lifecycle roots are direct children of one of these three
# directories.  Keep each search at depth 1 so private descendants such as
# /tmp/snap-private-tmp cannot turn this read-only inventory into a false
# failure (or be silently ignored with a blanket `find ... || true`).
for root in /mnt /mnt/jfs-tikv /tmp; do
  find "$root" -maxdepth 1 -mindepth 1 \( -name 'jfs-t64-*' -o -name 'jfs-t65-*' \) -printf '%y\t%p\t%u:%g\t%m\n'
done | sort
ps -eo pid=,ppid=,comm=,args= | awk '$3=="fio" || $0 ~ /jfs-t6[45]-/{print}'
printf 'section\topen-loops\n'
sudo losetup -l -n -O NAME,BACK-FILE
printf 'section\tread-only-complete\n'
REMOTE
}

: > "$OUT/summary.tsv"
for node in "${T65_NODES[@]}"; do
  file="$OUT/nodes/${node}.txt"
  remote_inventory "$node" > "$file"
  sha256sum "$file" >> "$OUT/summary.tsv"
done

sudo ceph health > "$OUT/ceph-health.txt"
sudo ceph -s > "$OUT/ceph-s.txt"
sudo ceph df --format=json > "$OUT/ceph-df.json"
[[ $(<"$OUT/ceph-health.txt") == HEALTH_OK ]] || t65_die 'Ceph is not HEALTH_OK'

python3 - "$OUT" <<'PY'
from pathlib import Path
import re, sys
root=Path(sys.argv[1]); nodes=sorted((root/'nodes').glob('*.txt'))
assert len(nodes)==3
uids=[]; avails=[]
for p in nodes:
    text=p.read_text()
    uid=re.search(r'^uid\t(\d+)$',text,re.M); gid=re.search(r'^gid\t(\d+)$',text,re.M)
    assert uid and gid
    uids.append((uid.group(1),gid.group(1)))
    fields=[x.split() for x in text.splitlines()]
    mount_rows=[x for x in fields if len(x)==5 and x[0]=='/dev/nvme1n1'
                and x[1]=='/mnt/jfs-tikv' and x[2]=='ext4']
    df_rows=[x for x in fields if len(x)==7 and x[0]=='/dev/nvme1n1'
             and x[1]=='ext4' and x[6]=='/mnt/jfs-tikv']
    assert len(mount_rows)==1, mount_rows
    assert len(df_rows)==1, df_rows
    avails.append(int(df_rows[0][4]))
    assert re.search(r'^unit\tpd\tactive\t',text,re.M)
    assert re.search(r'^unit\ttikv\tactive\t',text,re.M)
assert len(set(uids))==1, uids
assert min(avails)>=768*1024**3, avails
(root/'contract.tsv').write_text(
    f'uid\t{uids[0][0]}\n' f'gid\t{uids[0][1]}\n' f'min_avail_pre\t{min(avails)}\n' f'planned_bytes_per_node\t{256*1024**3}\n' f'production_reserve\t{512*1024**3}\n')
PY
printf '%s\n' "$(date +%s)" > "$OUT/INVENTORY_PASS"
printf 'INVENTORY_PASS run_id=%s evidence=%s\n' "$RUN_ID" "$OUT"
