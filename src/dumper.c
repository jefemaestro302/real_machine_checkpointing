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
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>

#include "checkpoint.h"
#include "dumper.h"

/* ------------------------------------------------------------------ */
/*  Internal helpers                                                     */
/* ------------------------------------------------------------------ */

int ckpt_dump_impl(const char *path, ckpt_regs_t *r);




/* ------------------------------------------------------------------ */
/*  Parse /proc/self/maps and populate region descriptors               */
/* ------------------------------------------------------------------ */

#define MAX_REGIONS 256

static int parse_maps(ckpt_region_t *regions, int max_regions,
                      uint64_t loader_va_hint)
{
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) {
        perror("ckpt: fopen /proc/self/maps");
        return -1;
    }

    int n = 0;
    char line[512];

    while (fgets(line, sizeof(line), f) && n < max_regions) {
        uint64_t start, end, inode;
        char perms[8], dev[8], name[256];
        unsigned long offset;
        name[0] = '\0';

        int parsed = sscanf(line, "%lx-%lx %7s %lx %7s %lu %255[^\n]",
                            &start, &end, perms, &offset, dev, &inode, name);
        if (parsed < 6) continue;

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

        strncpy(reg->name, nm, sizeof(reg->name) - 1);
        n++;
    }

    fclose(f);
    return n;
}

/* ------------------------------------------------------------------ */
/*  Write region payload to file                                         */
/* ------------------------------------------------------------------ */
static int dump_region_data(int fd, ckpt_region_t *reg)
{
    if (reg->flags & CKPT_FLAG_SKIP) {
        reg->data_size   = 0;
        reg->file_offset = 0;
        return 0;
    }

    /* Record current file position */
    off_t pos = lseek(fd, 0, SEEK_CUR);
    if (pos == (off_t)-1) { perror("ckpt: lseek"); return -1; }
    reg->file_offset = (uint64_t)pos;

    size_t  size = reg->end - reg->start;
    uint8_t *ptr = (uint8_t *)(uintptr_t)reg->start;

    /* Write in 4 KiB chunks to avoid large stack allocations */
    size_t written = 0;
    while (written < size) {
        size_t chunk = size - written;
        if (chunk > 4096) chunk = 4096;

        ssize_t r = write(fd, ptr + written, chunk);
        if (r <= 0) {
            if (errno == EFAULT) {
                /* Page not readable (e.g. guard page) — zero-fill */
                static const uint8_t zeros[4096] = {0};
                write(fd, zeros, chunk);
            } else {
                perror("ckpt: write");
                return -1;
            }
        }
        written += (r > 0 ? (size_t)r : chunk);
    }

    reg->data_size = (uint64_t)size;
    return 0;
}

/* ================================================================== */
/*  Public API                                                          */
/* ================================================================== */

int ckpt_dump_impl(const char *path, ckpt_regs_t *r)
{
    fprintf(stderr, "[ckpt] Starting dump to: %s\n", path);

    /* 1. Capture ROI entry RIP.
     * With the naked ckpt_dump, r->rip ALREADY contains the correct ROI RIP.
     */
    uint64_t roi_rip = r->rip;
    fprintf(stderr, "[ckpt] ROI RIP (from naked capture): 0x%lx\n", roi_rip);

    /* 2. Parse /proc/self/maps */
    static ckpt_region_t regions[MAX_REGIONS];
    int num_regions = parse_maps(regions, MAX_REGIONS, 0);
    if (num_regions < 0) return -1;

    fprintf(stderr, "[ckpt] Found %d memory regions\n", num_regions);

    /* 3. Open output file */
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) { perror("ckpt: open"); return -1; }

    /* 4. Write placeholder header + region descriptors (we'll patch later) */
    ckpt_header_t hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = CKPT_MAGIC;
    hdr.version = CKPT_VERSION;
    hdr.num_regions = (uint32_t)num_regions;
    memcpy(&hdr.regs, r, sizeof(ckpt_regs_t));
    hdr.roi_entry_rip = r->rip;
    hdr.stack_va = r->rsp;

    if (write(fd, &hdr, sizeof(hdr)) != sizeof(hdr)) {
        perror("ckpt: write header"); close(fd); return -1;
    }
    /* Write region descriptors (placeholders, offsets filled after) */
    if (write(fd, regions, num_regions * sizeof(ckpt_region_t)) !=
              (ssize_t)(num_regions * sizeof(ckpt_region_t))) {
        perror("ckpt: write descriptors"); close(fd); return -1;
    }

    /* 5. Write actual memory payloads and record offsets */
    for (int i = 0; i < num_regions; i++) {
        if (dump_region_data(fd, &regions[i]) < 0) {
            fprintf(stderr, "[ckpt] Warning: failed to dump region %d (%s)\n",
                    i, regions[i].name);
        }
    }

    /* 6. Patch region descriptors with correct file_offset / data_size */
    if (lseek(fd, (off_t)CKPT_REGIONS_OFFSET, SEEK_SET) == (off_t)-1) {
        perror("ckpt: lseek patch"); close(fd); return -1;
    }
    if (write(fd, regions, num_regions * sizeof(ckpt_region_t)) !=
              (ssize_t)(num_regions * sizeof(ckpt_region_t))) {
        perror("ckpt: write descriptors patch"); close(fd); return -1;
    }

    close(fd);

    fprintf(stderr, "[ckpt] Dump complete. ROI RIP=0x%lx, RSP=0x%lx\n",
            roi_rip, r->rsp);
    return 0;
}
