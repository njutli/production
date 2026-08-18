vfs: dispatch complete blocks after preparing slice ID

The first write to a new slice can fill a complete block before the
asynchronously allocated slice ID is ready. In that case the write path
skips FlushTo because the ID is still zero, and the ID-ready path does not
revisit the missed dispatch.

After assigning the ID, dispatch complete blocks for a non-frozen slice.
Record a FlushTo failure as EIO so it remains observable by later flushes.
Add deterministic in-memory tests for full, partial, and error paths.
