/**
 * dumper.c - Memory/register dumper called at the ROI entry point
 *
 * Usage (inside the Tailbench application):
 *   #include "checkpoint.h"
 *   #include "dumper.h"
 *
 *   // At the ROI start:
 *   ckpt_dump("dump.ckpt");
 *   // ... ROI code continues normally on FIRST run.
 *   //     On restore, the loader jumps directly here.
 *
 * Compilation: link with -static, no glibc ctor side effects after restore.
 *
 * ASYNC-SIGNAL SAFETY: ckpt_dump_impl() is normally called from a signal
 * handler (SIGUSR1 / SIGTRAP in libckpt.c) that may have interrupted the
 * application at ANY point, including inside malloc() or printf() while
 * they hold internal locks. Everything reachable from here must therefore
 * avoid stdio streams and the heap: /proc/self/maps is read with raw
 * open/read into a static buffer and all logging goes through ckpt_log(),
 * which formats into a static buffer and emits it with write(2).
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <asm/prctl.h>

#include "checkpoint.h"
#include "dumper.h"

/* ------------------------------------------------------------------ */
/*  Internal helpers                                                     */
/* ------------------------------------------------------------------ */

int ckpt_dump_impl(const char *path, ckpt_regs_t *r);

/* Signal-safe logger: vsnprintf does not allocate for the conversions
 * used here, and write(2) is async-signal-safe. Not reentrant, which is
 * fine: only one dump can ever be in progress (g_dumped in libckpt.c). */
void ckpt_log(const char *fmt, ...)
{
    static char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof(buf)) n = sizeof(buf) - 1;
    ssize_t off = 0;
    while (off < n) {
        ssize_t w = write(STDERR_FILENO, buf + off, (size_t)(n - off));
        if (w <= 0) { if (w < 0 && errno == EINTR) continue; break; }
        off += w;
    }
}

/* write() the whole buffer, retrying on short writes and EINTR */
static int write_all(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/*  Parse /proc/self/maps and populate region descriptors               */
/* ------------------------------------------------------------------ */

#define MAX_REGIONS   1024
#define MAPS_BUF_SZ   (512 * 1024)

static int parse_maps(ckpt_region_t *regions, int max_regions,
                      uint64_t loader_va_hint)
{
    /* No fopen(): it calls malloc(), which may deadlock if the signal
     * interrupted the application inside malloc(). */
    static char maps[MAPS_BUF_SZ];
    int mfd = open("/proc/self/maps", O_RDONLY);
    if (mfd < 0) {
        ckpt_log("[ckpt] ERROR: open /proc/self/maps: %s\n", strerror(errno));
        return -1;
    }
    size_t len = 0;
    for (;;) {
        if (len == sizeof(maps) - 1) {
            ckpt_log("[ckpt] ERROR: /proc/self/maps larger than %d bytes\n",
                     MAPS_BUF_SZ);
            close(mfd);
            return -1;
        }
        ssize_t r = read(mfd, maps + len, sizeof(maps) - 1 - len);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) {
            ckpt_log("[ckpt] ERROR: read /proc/self/maps: %s\n", strerror(errno));
            close(mfd);
            return -1;
        }
        if (r == 0) break;
        len += (size_t)r;
    }
    close(mfd);
    maps[len] = '\0';

    int n = 0;
    char *line = maps;
    while (*line) {
        char *nl = strchr(line, '\n');
        if (nl) *nl = '\0';

        uint64_t start, end, inode;
        char perms[8], dev[16], name[256];
        unsigned long offset;
        name[0] = '\0';

        int parsed = sscanf(line, "%lx-%lx %7s %lx %15s %lu %255[^\n]",
                            &start, &end, perms, &offset, dev, &inode, name);
        line = nl ? nl + 1 : line + strlen(line);
        if (parsed < 6) continue;

        if (n >= max_regions) {
            /* Silently dropping a region would produce a checkpoint that
             * restores with memory missing. Refuse instead. */
            ckpt_log("[ckpt] ERROR: more than %d memory regions\n", max_regions);
            return -1;
        }

        /* Trim leading whitespace from name */
        char *nm = name;
        while (*nm == ' ') nm++;

        ckpt_region_t *reg = &regions[n];
        memset(reg, 0, sizeof(*reg));

        reg->start = start;
        reg->end   = end;

        /* prot flags */
        reg->prot = 0;
        if (perms[0] == 'r') reg->prot |= CKPT_PROT_R;
        if (perms[1] == 'w') reg->prot |= CKPT_PROT_W;
        if (perms[2] == 'x') reg->prot |= CKPT_PROT_X;

        /* Classification */
        reg->flags = 0;
        if (inode == 0) reg->flags |= CKPT_FLAG_ANONYMOUS;

        bool is_text  = (reg->prot & CKPT_PROT_X) != 0;
        bool is_stack = (strstr(nm, "[stack]") != NULL);
        bool is_heap  = (strstr(nm, "[heap]")  != NULL);
        bool is_vsyscall  = (strstr(nm, "[vsyscall]") != NULL);

        if (is_stack) reg->flags |= CKPT_FLAG_STACK;
        if (is_heap)  reg->flags |= CKPT_FLAG_HEAP;
        if (is_text)  reg->flags |= CKPT_FLAG_TEXT;

        /* Skip vsyscall - hard to restore */
        if (is_vsyscall) {
            reg->flags |= CKPT_FLAG_SKIP;
        }

        /* Skip regions that contain the loader itself (avoid clobbering
         * during restore if the loader is mapped somewhere in our VA). */
        if (loader_va_hint &&
            start <= loader_va_hint && loader_va_hint < end) {
            reg->flags |= CKPT_FLAG_SKIP;
        }

        /* Regions with no read permission cannot be dumped */
        if (!(reg->prot & CKPT_PROT_R)) {
            reg->flags |= CKPT_FLAG_SKIP;
        }

        /* name is diagnostic only: truncate to the descriptor's field */
        size_t nlen = strlen(nm);
        if (nlen >= sizeof(reg->name)) nlen = sizeof(reg->name) - 1;
        memcpy(reg->name, nm, nlen);
        reg->name[nlen] = '\0';
        n++;
    }

    return n;
}

/* ------------------------------------------------------------------ */
/*  Parse /proc/self/fd and populate fd descriptors                     */
/* ------------------------------------------------------------------ */

#define MAX_FDS 256

static int parse_fds(ckpt_fd_t *fds, int max_fds, int exclude_fd)
{
    int n = 0;
    /* In simulation environments (like gem5 SE), opendir("/proc/self/fd")
       and getdents might not be fully supported or could behave unexpectedly.
       It is safer to brute-force probe file descriptors up to a typical limit. */
    for (int fd = 0; fd < 256 && n < max_fds; fd++) {
        if (fd == exclude_fd) continue;

        /* fcntl(F_GETFL) is a very safe syscall to check if an FD is open */
        int flags = fcntl(fd, F_GETFL);
        if (flags == -1) continue;

        char path[64];
        snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);

        char target[sizeof(fds[0].path)];
        ssize_t len = readlink(path, target, sizeof(target) - 1);
        if (len < 0) {
            /* Fallback if readlink fails in simulation but FD is open */
            snprintf(target, sizeof(target), "unknown_fd_%d", fd);
        } else if ((size_t)len == sizeof(target) - 1) {
            /* readlink() truncates silently: a truncated path would make
             * the loader reopen the wrong file. Keep the fd out of the
             * checkpoint's restorable set instead. */
            ckpt_log("[ckpt] WARNING: path of fd %d longer than %zu bytes, "
                     "it will not be restored\n", fd, sizeof(target) - 2);
            snprintf(target, sizeof(target), "path_too_long_fd_%d", fd);
        } else {
            target[len] = '\0';
        }

        off_t offset = lseek(fd, 0, SEEK_CUR);
        if (offset == (off_t)-1) offset = 0;

        fds[n].fd = fd;
        fds[n].flags = flags;
        fds[n].offset = offset;
        strncpy(fds[n].path, target, sizeof(fds[n].path) - 1);
        fds[n].path[sizeof(fds[n].path) - 1] = '\0';
        n++;
    }

    /* Working directory as a pseudo-descriptor (readlink is signal-safe) */
    if (n < max_fds) {
        char cwd[sizeof(fds[0].path)];
        ssize_t len = readlink("/proc/self/cwd", cwd, sizeof(cwd) - 1);
        if (len > 0 && (size_t)len < sizeof(cwd) - 1) {
            cwd[len] = '\0';
            memset(&fds[n], 0, sizeof(fds[n]));
            fds[n].fd = CKPT_FD_CWD;
            fds[n].flags = O_RDONLY | O_DIRECTORY;
            memcpy(fds[n].path, cwd, (size_t)len + 1);
            n++;
        } else {
            ckpt_log("[ckpt] WARNING: working directory not recorded\n");
        }
    }
    return n;
}

/* ------------------------------------------------------------------ */
/*  Write region payload to file                                         */
/*  cur_off: current absolute write position in the file (in/out).      */
/*  This avoids lseek(SEEK_CUR) which is unreliable on network FSes.   */
/* ------------------------------------------------------------------ */
static int dump_region_data(int fd, ckpt_region_t *reg, uint64_t *cur_off)
{
    if (reg->flags & CKPT_FLAG_SKIP) {
        reg->data_size   = 0;
        reg->file_offset = 0;
        return 0;
    }

    reg->file_offset = *cur_off;

    size_t  size = reg->end - reg->start;
    uint8_t *ptr = (uint8_t *)(uintptr_t)reg->start;

    /* Write in 4 KiB chunks to avoid large stack allocations */
    size_t written = 0;
    while (written < size) {
        size_t chunk = size - written;
        if (chunk > 4096) chunk = 4096;

        ssize_t r = write(fd, ptr + written, chunk);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) {
            if (r < 0 && errno == EFAULT) {
                /* Page not readable (e.g. guard page) -- zero-fill */
                static const uint8_t zeros[4096] = {0};
                if (write_all(fd, zeros, chunk) < 0) {
                    ckpt_log("[ckpt] ERROR: write: %s\n", strerror(errno));
                    return -1;
                }
                written += chunk;
            } else {
                ckpt_log("[ckpt] ERROR: write: %s\n",
                         r < 0 ? strerror(errno) : "0 bytes written");
                return -1;
            }
        } else {
            written += (size_t)r;
        }
    }

    reg->data_size = (uint64_t)written;
    *cur_off += written;
    ckpt_log("[ckpt] region %lx-%lx: file_offset=%lu data_size=%lu\n",
             (unsigned long)reg->start, (unsigned long)reg->end,
             (unsigned long)reg->file_offset, (unsigned long)reg->data_size);
    return 0;
}

/* ================================================================== */
/*  Public API                                                          */
/* ================================================================== */

int ckpt_dump_impl(const char *path, ckpt_regs_t *r)
{
    ckpt_log("[ckpt] Starting dump to: %s\n", path);

    /* 1. Capture ROI entry RIP.
     * With the naked ckpt_dump, r->rip ALREADY contains the correct ROI RIP.
     */
    uint64_t roi_rip = r->rip;
    ckpt_log("[ckpt] ROI RIP (from naked capture): 0x%lx\n", roi_rip);

    /* 2. Parse /proc/self/maps */
    static ckpt_region_t regions[MAX_REGIONS];
    int num_regions = parse_maps(regions, MAX_REGIONS, 0);
    if (num_regions < 0) return -1;

    ckpt_log("[ckpt] Found %d memory regions\n", num_regions);

    /* Safely fetch fs_base and gs_base via arch_prctl to avoid illegal instructions on older CPUs */
    syscall(SYS_arch_prctl, ARCH_GET_FS, &r->fs_base);
    syscall(SYS_arch_prctl, ARCH_GET_GS, &r->gs_base);

    /* 3. Open output file.
     * The dump is written to "<path>.tmp" and renamed to <path> only once
     * it is complete, so the final name never refers to a half-written
     * checkpoint (e.g. if the process is killed mid-dump). */
    static char tmp_path[4096];
    if ((size_t)snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", path) >= sizeof(tmp_path)) {
        ckpt_log("[ckpt] ERROR: output path too long\n");
        return -1;
    }
    int fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        ckpt_log("[ckpt] ERROR: open %s: %s\n", tmp_path, strerror(errno));
        return -1;
    }

    /* Parse open file descriptors */
    static ckpt_fd_t fds[MAX_FDS];
    int num_fds = parse_fds(fds, MAX_FDS, fd);
    ckpt_log("[ckpt] Found %d open file descriptors\n", num_fds);

    /* 4. Write placeholder header + region descriptors + fd descriptors */
    static ckpt_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = CKPT_MAGIC;
    hdr.version = CKPT_VERSION;
    hdr.num_regions = (uint32_t)num_regions;
    hdr.num_fds = (uint32_t)num_fds;
    memcpy(&hdr.regs, r, sizeof(ckpt_regs_t));
    hdr.roi_entry_rip = r->rip;
    hdr.stack_va = r->rsp;

    if (write_all(fd, &hdr, sizeof(hdr)) < 0) {
        ckpt_log("[ckpt] ERROR: write header: %s\n", strerror(errno));
        goto fail;
    }
    /* Write region descriptors (placeholders, offsets filled after) */
    if (write_all(fd, regions, num_regions * sizeof(ckpt_region_t)) < 0) {
        ckpt_log("[ckpt] ERROR: write descriptors: %s\n", strerror(errno));
        goto fail;
    }

    /* Write FD descriptors */
    if (write_all(fd, fds, num_fds * sizeof(ckpt_fd_t)) < 0) {
        ckpt_log("[ckpt] ERROR: write fds: %s\n", strerror(errno));
        goto fail;
    }

    /* 5. Write actual memory payloads and record offsets.
     * cur_off tracks the absolute file position so we never need lseek(SEEK_CUR),
     * which is unreliable on beegfs / NFS.
     * Any failure aborts the dump: after a partial write the offsets of
     * every following region would be wrong. */
    uint64_t cur_off = (uint64_t)CKPT_DATA_OFFSET(num_regions, num_fds);
    for (int i = 0; i < num_regions; i++) {
        if (dump_region_data(fd, &regions[i], &cur_off) < 0) {
            ckpt_log("[ckpt] ERROR: failed to dump region %d (%s)\n",
                     i, regions[i].name);
            goto fail;
        }
    }

    /* 6. Patch region descriptors with correct file_offset / data_size.
     * Use pwrite to avoid depending on the fd's current position. */
    ssize_t desc_sz = (ssize_t)((uint64_t)num_regions * sizeof(ckpt_region_t));
    ssize_t pw = pwrite(fd, regions, (size_t)desc_sz, (off_t)sizeof(ckpt_header_t));
    ckpt_log("[ckpt] pwrite descriptors: returned=%ld expected=%ld\n", (long)pw, (long)desc_sz);
    if (pw != desc_sz) {
        ckpt_log("[ckpt] ERROR: pwrite descriptors patch: %s\n", strerror(errno));
        goto fail;
    }

    if (fsync(fd) < 0 && errno != EINVAL) {
        ckpt_log("[ckpt] ERROR: fsync: %s\n", strerror(errno));
        goto fail;
    }
    if (close(fd) < 0) {
        fd = -1;
        ckpt_log("[ckpt] ERROR: close: %s\n", strerror(errno));
        goto fail;
    }
    fd = -1;
    if (rename(tmp_path, path) < 0) {
        ckpt_log("[ckpt] ERROR: rename %s -> %s: %s\n", tmp_path, path, strerror(errno));
        goto fail;
    }

    ckpt_log("[ckpt] Dump complete. ROI RIP=0x%lx, RSP=0x%lx\n",
             roi_rip, r->rsp);
    return 0;

fail:
    if (fd >= 0) close(fd);
    unlink(tmp_path);
    return -1;
}
