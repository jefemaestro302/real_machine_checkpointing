/**
 * dumper.h - Public API for the checkpoint dumper
 */
#ifndef DUMPER_H
#define DUMPER_H

/**
 * ckpt_dump() - Capture current process state and write it to a file.
 *
 * @path: Output file path (e.g. "dump.ckpt")
 *
 * Call this at the ROI entry point inside your Tailbench application.
 * When the loader restores the checkpoint, execution will resume at the
 * instruction immediately following the call to ckpt_dump() in the caller.
 *
 * Returns 0 on success, -1 on error.
 *
 * NOTE: After ckpt_dump() returns, the original application continues
 *       executing normally (first run semantics).  The loader will invoke
 *       it again starting at the ROI entry (restore semantics).
 */
int ckpt_dump(const char *path);

#endif /* DUMPER_H */
