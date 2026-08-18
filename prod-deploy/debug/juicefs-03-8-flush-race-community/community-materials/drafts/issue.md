# Issue Title

VFS may miss dispatching a full block when the slice ID is prepared asynchronously

# Issue Body

## What happened

When a write creates a new slice, `prepareID` runs asynchronously. If the first write fills a
complete block before the slice ID is ready, `sliceWriter.write` skips `FlushTo` because
`s.id == 0`. When the ID later becomes ready, the current ID-ready path calls `SetID` but does
not revisit the missed dispatch.

## What was expected

After the slice ID becomes available, a non-frozen slice that already contains at least one
complete block should dispatch the available data. A partial slice should retain the existing
behavior, and a dispatch error should remain observable by the later flush path.

## Minimal reproduction

The proposed in-memory regression test delays `NewSlice`, writes one complete block, and then
releases ID allocation. On official main commit
`53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`, the full-block and error-path tests fail with their
target markers while the partial-block control passes.

Adding a conditional catch-up `FlushTo` after `SetID` makes all three tests pass without making
slice-ID allocation synchronous.

## Environment and scope

- JuiceFS main: `53835e2481f45cba159cdbcc1ce0f1fc576e3f1a`
- writer.go blob: `91297fa4b8bbcea99bcff69c7b466884e33b1011`
- Go: 1.26.0
- OS/arch: Linux amd64

Local targeted count/race tests, internal semantic tests, the full `pkg/vfs` suite, vet, Linux
build and a clean patch replay completed successfully. GitHub Actions has not yet run. This issue
describes the deterministic dispatch behavior; it does not claim a completed v1.3 production
performance validation.
