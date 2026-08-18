# PR Title

vfs: dispatch complete blocks after preparing slice ID

# PR Body

## What does this PR do?

After an asynchronously allocated slice ID is assigned, dispatch data that already contains at
least one complete block.

The catch-up is limited to a positive ID, a non-frozen slice and `slen >= blockSize`. A
`FlushTo` error is recorded as `EIO`, matching the existing write/flush error model.

## Why is this needed?

The first write to a new slice can fill a complete block while `s.id` is still zero. The write
path then skips `FlushTo`, and the existing ID-ready path only calls `SetID`. Without a later
write or freeze, the missed full block is not dispatched promptly.

## Tests

On official main commit `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`:

- stock deterministic controls: full-block and error-path tests reproduced the target failure;
  the partial-block control passed;
- patched three-test single, `-count=100` and `-race -count=20` commands;
- ten internal semantic/fault/concurrency tests with count and race coverage;
- `go test ./pkg/vfs -count=1` with an isolated Redis instance;
- `gofmt`, `git diff --check`, `go vet ./pkg/vfs`, and `make juicefs`;
- standard apply and targeted replay in a fresh source tree.

GitHub Actions has not yet run. Real v1.3 Ceph S/A/B performance validation is tracked separately
and is not used as a correctness claim for this main-branch change.
