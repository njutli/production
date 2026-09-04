#!/usr/bin/env bash
# Phase I read-only inventory and concrete plan renderer. SSH commands are read-only.
set -euo pipefail
export LC_ALL=C
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); source "$DIR/s04a1-common.sh"
ACTION=${1:-}; RUN_ID=${2:-}; s04a1_check_run_id "$RUN_ID"
ROOT=${S04A1_EVIDENCE_ROOT:-/mnt/c/SunRise/test/04-2/$RUN_ID/phase1}
case "$ACTION" in
  plan)
    printf 'PHASE0_ONLY\trun_id\t%s\n' "$RUN_ID"
    printf 'REMOTE_RESULT_ROOT\tNONE\nPRODUCTION_PD\tMUST_NOT_STOP\n'
    printf 'MATRIX\tC,L,L,C,L,C,C,L\n'
    printf 'PLAN\tread-only inventory; no remote connection\n'
    printf 'PLAN\tproduction-stop/start,storage,cluster,fio\tNOT_READY\n'
    printf 'PLAN\tcapacity,maintenance,scrub leases\tcollect after Phase I authorization\n'
    ;;
  local-contract)
    printf 'run_id\t%s\n' "$RUN_ID"
    printf 'node_set\t10.20.1.150,10.20.1.151,10.20.1.152\n'
    printf 'native_root\t/mnt/jfs-tikv/jfs-s04a1-%s-c-<NODE>\n' "$RUN_ID"
    printf 'loop_backing\t/mnt/jfs-tikv/jfs-s04a1-%s-l-backing/<NODE>.img\n' "$RUN_ID"
    printf 'phase0_boundary\tNO_REMOTE_NO_MUTATION\n'
    ;;
  collect)
    mkdir -p "$ROOT/inventory" "$ROOT/plans"
    SSH=(ssh -F /home/lilingfeng/.ssh/config -o BatchMode=yes -o ConnectTimeout=8)
    # Collection is executed on 157 (thailand); 157 then reaches the three
    # storage nodes with their existing sunrise key.  WSL never dials 150-152.
    if [[ ${S04A1_SIDE157:-0} == 1 ]]; then
      SSH157=(ssh -o BatchMode=yes -o ConnectTimeout=8)
      SSH=(bash -c '"$@"' _)
    fi
    hosts=(thailand 10.20.1.150 10.20.1.151 10.20.1.152)
    for host in "${hosts[@]}"; do
      safe=${host//./_}
      cmd='printf "host\\t%s\\n" "$(hostname)"; id; date -Is; uname -a; printf "ips\\t"; hostname -I; printf "\\nunits\\n"; for u in pd tikv; do systemctl is-active "$u" 2>/dev/null || true; systemctl show "$u" -p MainPID -p FragmentPath -p ExecStart 2>/dev/null || true; done; printf "mounts\\n"; findmnt -rn -o SOURCE,TARGET,FSTYPE,UUID,OPTIONS; printf "capacity\\n"; df -B1 -T /mnt/jfs-tikv 2>&1 || true; printf "processes\\n"; ps -eo pid,ppid,lstart,comm,args; printf "fio\\n"; pgrep -x fio || true; printf "cephconf\\n"; if test -r /etc/ceph/ceph.conf; then sha256sum /etc/ceph/ceph.conf; else echo unavailable; fi; printf "health\\n"; sudo -n ceph health 2>&1 || true; printf "pdhealth\\n"; curl -fsS --connect-timeout 3 --max-time 8 http://127.0.0.1:2379/pd/api/v1/health 2>&1 || true; printf "tikvhealth\\n"; curl -fsS --connect-timeout 3 --max-time 8 http://127.0.0.1:20180/metrics 2>&1 | head -c 4096 || true'
      if [[ ${S04A1_SIDE157:-0} == 1 && $host != thailand ]]; then
        "${SSH157[@]}" "sunrise@$host" "$cmd" > "$ROOT/inventory/$safe.tsv" 2>&1 || printf 'SSH_READONLY_FAILED\thost=%s\n' "$host" > "$ROOT/inventory/$safe.error"
      else
        eval "$cmd" > "$ROOT/inventory/$safe.tsv" 2>&1 || printf 'LOCAL_READONLY_FAILED\thost=%s\n' "$host" > "$ROOT/inventory/$safe.error"
      fi
    done
    # H contract is inspected without creating, truncating, or laying out files.
    if [[ ${S04A1_SIDE157:-0} == 1 ]]; then
      find /mnt/juicefs/test_dir -maxdepth 1 -type f \( -name 'storage_test.*.0' -o -name 'rw_test.*.0' \) -printf '%p\t%s\t%i\t%T@\n' 2>/dev/null | sort > "$ROOT/inventory/h-files.tsv" 2>&1 || true
    else
      "${SSH[@]}" thailand 'find /mnt -maxdepth 4 -type f \( -name "storage_test.*.0" -o -name "rw_test.*.0" \) -printf "%p\\t%s\\t%i\\t%T@\\n" 2>/dev/null | sort' > "$ROOT/inventory/h-files.tsv" 2>&1 || true
    fi
    {
      printf 'run_id\tnode\trole\tpath\taction\tauthority\n'
      for n in 10.20.1.150 10.20.1.151 10.20.1.152; do
        printf '%s\t%s\tproduction\tservice:tikv\tSTOP/START (print only)\tNOT_AUTHORIZED\n' "$RUN_ID" "$n"
        printf '%s\t%s\tproduction\tservice:pd\tNEVER_STOP\tFORBIDDEN\n' "$RUN_ID" "$n"
        printf '%s\t%s\tC\t/mnt/jfs-tikv/jfs-s04a1-%s-c-%s\tcreate/mount/destroy (print only)\tPHASE_III\n' "$RUN_ID" "$n" "$RUN_ID" "${n##*.}"
        printf '%s\t%s\tL\t/mnt/jfs-tikv/jfs-s04a1-%s-l-backing/%s.img\tfallocate/loop/mkfs/mount/destroy (print only)\tPHASE_III\n' "$RUN_ID" "$n" "$RUN_ID" "${n##*.}"
      done
    } > "$ROOT/plans/maintenance-budget.tsv"
    cp "$ROOT/plans/maintenance-budget.tsv" "$ROOT/plans/capacity-plan.tsv"
    for p in prod-stop prod-start storage-create storage-destroy scrub-pause-restore; do
      { printf 'run_id\tnode\taction\tcommand\texecution\n'; for n in 10.20.1.150 10.20.1.151 10.20.1.152; do printf '%s\t%s\t%s\tPLAN_ONLY\tNOT_EXECUTED\n' "$RUN_ID" "$n" "$p"; done; } > "$ROOT/plans/$p-plan.tsv"
    done
    if compgen -G "$ROOT/inventory/*.error" >/dev/null; then
      printf 'INVENTORY_BLOCKED\tread-only SSH identity/reachability failure; inspect *.error\n' >&2
      return 42
    fi
    printf 'INVENTORY_PASS\troot=%s\n' "$ROOT"
    ;;
  *) s04a1_die 'usage: inventory plan|local-contract RUN_ID';;
esac
