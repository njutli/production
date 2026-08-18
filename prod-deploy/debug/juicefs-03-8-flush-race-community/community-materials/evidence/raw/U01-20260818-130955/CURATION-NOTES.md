# U01 selected raw evidence

Source run:

- RUN_ID: `20260818-130955`
- frozen main: `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`
- original OUT: `/home/lilingfeng/tmp/juicefs-u01-20260818-130955`
- reviewed report: `../../../reports/U01-execution-20260818-130955.md`

The `logs/`, `rc/`, `meta/`, `diffs/`, `redis/`, `artifacts/`, result tables,
`commands.sh`, `adaptations.tsv`, claim and draft notes were copied byte-for-byte from the
preserved U01 OUT. Full source clones, `.git`, build binaries, frozen duplicate inputs,
authorization/control files and the U01 tar were intentionally excluded.

`raw-evidence.tsv` lists every raw path used by the U01 producer's technical result. Each listed
path exists under this directory with the recorded size and SHA256. `commands.sh` and
`adaptations.tsv` are retained as useful execution summaries, but they were created after the
original U01 tar and were not members of that archive.

Evidence boundary:

- stock/B/Q/full-vfs/replay raw logs and rc are technical evidence;
- non-verbose count/race logs show package success rather than individual PASS lines, so exact
  repetition totals are inferred from anchored command arguments plus rc=0;
- the original archive is not promoted as complete; see the Codex section of the reviewed report;
- `artifacts/community-candidate-latest.patch` uses abbreviated git index IDs. The authoritative
  community candidate at `../../../candidate/community-candidate.patch` uses full index IDs and
  has identical hunks and file contents;
- this directory is for local review and selective maintainer follow-up, not bulk upload.
