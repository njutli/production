# U01 Draft Update Notes

## Latest commit
- LATEST_MAIN: 53835e2481f45cba159cdbcc1ce0f1fc576e3f1a
- HISTORICAL_MAIN: 53835e2481f45cba159cdbcc1ce0f1fc576e3f1a
- SAME: true (main has not changed since C03)
- Commit title: "refactor/cache: rename disk cache (#7404)"
- Commit date: 2026-08-17 15:06:30 +0800

## Stock branch
- TARGET-BEHAVIOR-PRESENT
- U1 (TestFullBlockDispatchedWhenSliceIDBecomesReady): 10/10 independent processes FAIL with marker "full block was not dispatched after slice ID became ready" (rc=1, marker count=1 each)
- U2 (TestPartialBlockNotDispatchedWhenSliceIDBecomesReady): 1/1 PASS (rc=0)
- U3 (TestFlushErrorRecordedWhenSliceIDBecomesReady): 10/10 independent processes FAIL with marker "full block with injected flush error was not dispatched" (rc=1, marker count=1 each)
- No panic, DATA RACE, timeout, or build error in any run

## B branch
- Patch applied: standard git apply (no context-only port needed, LATEST_MAIN == HISTORICAL_MAIN)
- Patch SHA (writer-only): b259513ac5b15370e129f45e0f6b8804bb0a91b2d2f2985e6111e25ca4b95355
- Latest two-file patch SHA: c5b188451c47ca8c88b7814bf2c7ea066df77fc193442a75dfb84472bfd5b5ec
- B single: U1/U2/U3 all PASS (rc=0)
- B count=100: U1=100, U2=100, U3=100, all PASS (300 total, rc=0)
- B race=20: U1=20, U2=20, U3=20, all PASS (60 total, rc=0, no DATA RACE)
- Full pkg/vfs: PASS (rc=0, 13.049s)
- gofmt: clean (rc=0, empty output)
- git diff --check: clean (rc=0)
- go vet: clean (rc=0)
- make juicefs: PASS (rc=0), binary 126MB, SHA 9d34056c..., version 1.5.0-dev+2026-08-17.53835e2, deleted after evidence

## Q branch (C02 semantic)
- Q single: 10/10 PASS (rc=0)
- Q count=20: 200/200 PASS (rc=0)
- Q race=5: 50/50 PASS (rc=0, no DATA RACE)

## R branch (replay)
- Standard git apply: rc=0
- B/R diff: identical (writer diff SHA and test file SHA match)
- R single: U1/U2/U3 all PASS (rc=0)
- R count=20: U1=20, U2=20, U3=20, all PASS (60 total, rc=0)

## Redis
- Isolated container: redis-u01-20260818-130955
- Image: redis:7.2-alpine, RepoDigest: redis@sha256:05a97a479bc73de66f087dc05b569010772880f778cc8671fa6b8aadee32e5c6
- PONG confirmed
- Stopped and removed, port 6379 freed, name/label filters return 0

## SQLite temp file
- Generated during full pkg/vfs test: pkg/vfs/?_journal=WAL&_timeout=5000&cache=shared
- Before: not present
- Regular file (not symlink), SQLite 3.x database, 155648 bytes
- SHA256: 749091ccaa69aca013d36d41501163626bc9fff79e578a4320e60f6cdbec2206
- Deleted: exact file removed, gone confirmed

## Not run
- GitHub Actions CI
- Community write operations (commit/push/fork/issue/PR/comment)
- v1.3 Ceph performance
- fio/drop_caches/layout/cooldown (all N/A for pure Go replay)
