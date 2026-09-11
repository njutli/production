#!/usr/bin/env bash
set -euo pipefail

expected_host=ceph-node3
[[ $(hostname -s) == "$expected_host" ]] || { printf 'wrong host: %s\n' "$(hostname -s)" >&2; exit 1; }

printf 'host\t%s\n' "$(hostname -s)"
printf 'root_source\t%s\n' "$(findmnt -n -o SOURCE /)"
printf 'root_available_bytes\t%s\n' "$(df -B1 --output=avail / | awk 'NR==2 {print $1}')"
printf 'memory_available_kib\t%s\n' "$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"

for path in /opt/juicefs-portal /etc/juicefs-portal /var/lib/juicefs-portal /var/log/juicefs-portal; do
  if [[ -e "$path" ]]; then
    printf 'target_exists\t%s\n' "$path"
    exit 1
  fi
done

for port in 3000 8080 9090; do
  if ss -ltnH "sport = :$port" | grep -q .; then
    printf 'port_in_use\t%s\n' "$port"
    exit 1
  fi
done

findmnt -rn /mnt/jfs-tikv
findmnt -rn /mnt/dbwal
printf 'T05_NODE_PREFLIGHT_PASS\n'
