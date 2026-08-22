vfs: dispatch complete blocks after preparing slice ID

The first write to a new slice can fill a complete block before the
asynchronously allocated slice ID is ready. In that case the write path
skips FlushTo because the ID is still zero, and the ID-ready path does not
revisit the missed dispatch.

After assigning the ID, dispatch complete blocks for a non-frozen slice.
Record a FlushTo failure as EIO so it remains observable by later flushes.

On v1.3.x this bug causes a ~5.5x randwrite throughput collapse (551 vs
~3000 MiB/s with 256 KiB block size) due to data retention triggering
buffer throttle self-lock. Backporting this fix to 1.3.x resolves the
collapse; on main the missed dispatch is absorbed by other drainage paths
but the code path is still incorrect.
