#!/bin/bash
# U01 Complete Command Record
# RUN_ID: 20260818-130955
# LATEST_MAIN: 53835e2481f45cba159cdbcc1ce0f1fc576e3f1a
# Go: 1.26.0 linux/amd64, GOTOOLCHAIN=auto

export GOFLAGS=-mod=readonly
export GOTOOLCHAIN=auto
export GOPROXY=https://goproxy.cn,direct

# --- Step 2: Freeze latest main ---
git ls-remote https://github.com/juicedata/juicefs refs/heads/main
git clone --depth=1 https://github.com/juicedata/juicefs src/F-fetch
cd src/F-fetch && git checkout --detach 53835e2481f45cba159cdbcc1ce0f1fc576e3f1a

# --- Step 3: Create arms ---
for arm in S-stock B-candidate Q-semantic R-replay; do
    git clone --no-hardlinks src/F-fetch src/$arm
    cd src/$arm && git checkout --detach 53835e2481f45cba159cdbcc1ce0f1fc576e3f1a
done

# --- Step 4: S-stock oracle ---
cp INPUT/writer_flush_test.go src/S-stock/pkg/vfs/
# U2 single
go test -count=1 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
# U1 ten independent processes
for i in $(seq 1 10); do
    go test -count=1 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
done
# U3 ten independent processes
for i in $(seq 1 10); do
    go test -count=1 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/
done

# --- Step 6: B apply ---
cd src/B-candidate
git apply INPUT/async-catchup-main.patch
cp INPUT/writer_flush_test.go pkg/vfs/

# --- Step 7: B matrix ---
go test -count=1 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=1 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=1 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=100 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=100 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=100 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -race -count=20 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -race -count=20 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -race -count=20 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/

# --- Step 8: Q-semantic ---
cd src/Q-semantic
git apply INPUT/async-catchup-main.patch
cp INPUT/writer_flush_c02_test.go pkg/vfs/
Q_REGEX='^(TestC02FullBlockDispatchAfterDelayedID|TestC02MultiBlockDispatchUsesLatestLength|TestC02FlushToFailureIsObservable|TestC02PartialThenFullAfterIDDispatchesOnce|TestC02DelayedNewSliceDoesNotBlockWriteAt|TestC02NonEIONewSliceDoesNotRetryBeforeFlush|TestC02TransientEIORecoversOnFreeze|TestC02PermanentENOSPCAbortsFrozenSlice|TestC02FrozenSliceSkipsCatchupFlush|TestC02ConcurrentIndependentFullBlocks)$'
go test -v -count=1 -run "$Q_REGEX" ./pkg/vfs/
go test -count=20 -run "$Q_REGEX" ./pkg/vfs/
go test -race -count=5 -run "$Q_REGEX" ./pkg/vfs/

# --- Step 9: Redis + full vfs + quality gates ---
docker run -d --name redis-u01-20260818-130955 --label u01-run-id=20260818-130955 -p 127.0.0.1:6379:6379 redis:7.2-alpine
export REDIS_ADDR=redis://127.0.0.1:6379/13
cd src/B-candidate
go test ./pkg/vfs -count=1
gofmt -d pkg/vfs/writer.go pkg/vfs/writer_flush_test.go
git diff --check
go vet ./pkg/vfs
make juicefs
# Delete build product
rm juicefs
# Stop Redis
docker stop redis-u01-20260818-130955 && docker rm redis-u01-20260818-130955

# --- Step 10: R-replay ---
cd src/R-replay
git apply artifacts/community-candidate-latest.patch
go test -count=1 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=1 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=1 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=20 -run '^TestFullBlockDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=20 -run '^TestPartialBlockNotDispatchedWhenSliceIDBecomesReady$' ./pkg/vfs/
go test -count=20 -run '^TestFlushErrorRecordedWhenSliceIDBecomesReady$' ./pkg/vfs/
