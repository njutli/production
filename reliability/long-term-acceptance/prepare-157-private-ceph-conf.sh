#!/bin/bash
set -euo pipefail

ACTION=${1:-}
SRC=/tmp/t51-conf/ceph-msgr8.conf
DST=/home/sunrise/juicefs-ceph-msgr8.conf
SHA=c1e917e23b2888511aaffd55a2fb0697e8e3c9814180ea858eda500bc27bed48
[[ "$ACTION" == plan || "$ACTION" == execute || "$ACTION" == verify ]] || { echo 'usage: {plan|execute|verify}' >&2; exit 42; }
[[ $(hostname) == oneasia-c1-cpu-node10 && $(id -u) == 1002 ]] || { echo 'wrong host/user' >&2; exit 42; }
[[ "$DST" == /home/sunrise/juicefs-ceph-msgr8.conf && ! -L "$DST" ]] || { echo 'unsafe destination' >&2; exit 42; }
[[ -r "$SRC" && ! -L "$SRC" && $(sha256sum "$SRC" | awk '{print $1}') == "$SHA" ]] || { echo 'source mismatch' >&2; exit 42; }

if [[ "$ACTION" == verify ]]; then
  [[ -f "$DST" && $(sha256sum "$DST" | awk '{print $1}') == "$SHA" ]] || { echo 'destination mismatch' >&2; exit 42; }
  [[ $(ceph-conf --conf "$DST" --name client.admin --lookup ms_async_op_threads) == 8 ]] || { echo 'private Ceph setting mismatch' >&2; exit 42; }
  echo 'PRIVATE_CEPH_CONF_VERIFY_PASS'
  exit 0
fi

[[ ! -e "$DST" ]] || { echo 'destination already exists; refuse overwrite' >&2; exit 42; }
printf 'WILL_EXECUTE: install -m 0600 %s %s\n' "$SRC" "$DST"
if [[ "$ACTION" == plan ]]; then exit 0; fi
[[ ${LT_CONF_ACK:-} == I_ACK_157_PRIVATE_CEPH_CONF ]] || { echo 'ACK missing' >&2; exit 42; }
install -m 0600 -- "$SRC" "$DST"
bash "$0" verify
