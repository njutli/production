#!/usr/bin/env bash
set -euo pipefail

[[ $(hostname -s) =~ ^ceph-node[12]$ ]] || { printf 'must run on ceph-node1 or ceph-node2\n' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { printf 'must run as root\n' >&2; exit 1; }
command -v cephadm >/dev/null
cephadm shell -- ceph -s
cephadm shell -- ceph mgr dump -f json-pretty
cephadm shell -- ceph mgr module ls -f json-pretty
cephadm shell -- ceph config get mgr mgr/prometheus/server_addr || true
cephadm shell -- ceph config get mgr mgr/prometheus/server_port || true
cephadm shell -- ceph orch ps --daemon-type mgr -f json-pretty
printf 'T06_CEPH_READONLY_INVENTORY_PASS\n'
