/**
 * checkpoint.h - Shared protocol between the target application
 *                and the custom loader (checkpoint/restore PoC)
 *
 * Context: gem5 SE mode, static binary, single-thread, ASLR off
 * Strategy: Option 2 - Raw memory dump + custom loader
 *
 * The dump file layout is:
 *   [ckpt_header_t]
 *   [N × ckpt_region_t]   (region descriptors, N == header.num_regions)
 *   [raw bytes for each region, in order]
 */

#ifndef CHECKPOINT_H
#define CHECKPOINT_H

#include <stdint.h>
#include <sys/types.h>

/* ------------------------------------------------------------------ */
/*  Magic + version                                                      */
/* ------------------------------------------------------------------ */
#define CKPT_MAGIC   0x474D35434B505400ULL  /* "GM5CKPT\0" */
#define CKPT_VERSION 1

/* ------------------------------------------------------------------ */
/*  x86-64 general-purpose + special registers                          */
/* ------------------------------------------------------------------ */
typedef struct {
    /* General purpose */
    uint64_t rax, rbx, rcx, rdx;
    uint64_t rsi, rdi, rbp, rsp;
    uint64_t r8,  r9,  r10, r11;
    uint64_t r12, r13, r14, r15;
    /* Control */
    uint64_t rip;
    uint64_t rflags;
    /* Segment selectors (values at checkpoint time) */
    uint64_t cs, ss, ds, es, fs, gs;
    /* FS/GS base (TLS) */
    uint64_t fs_base, gs_base;
} ckpt_regs_t;

/* ------------------------------------------------------------------ */
/*  Description of one contiguous virtual-memory region                 */
/* ------------------------------------------------------------------ */
#define CKPT_PROT_R  0x01
#define CKPT_PROT_W  0x02
#define CKPT_PROT_X  0x04

#define CKPT_FLAG_ANONYMOUS  0x01   /* not backed by a file */
#define CKPT_FLAG_STACK      0x02   /* this is the stack region */
#define CKPT_FLAG_HEAP       0x04
#define CKPT_FLAG_TEXT       0x08   /* .text/.rodata - usually skip payload */
#define CKPT_FLAG_DATA       0x10   /* .data/.bss */
#define CKPT_FLAG_SKIP       0x80   /* loader should mmap but NOT overwrite */

typedef struct {
    uint64_t start;       /* region start VA */
    uint64_t end;         /* region end VA   (exclusive) */
    uint32_t prot;        /* CKPT_PROT_* bitmask */
    uint32_t flags;       /* CKPT_FLAG_* bitmask */
    uint64_t file_offset; /* offset into the dump file where raw bytes start */
    uint64_t data_size;   /* number of raw bytes stored (may == 0 for SKIP)  */
    char     name[64];    /* /proc/maps name field, for diagnostics */
} ckpt_region_t;

/* ------------------------------------------------------------------ */
/*  Top-level file header                                               */
/* ------------------------------------------------------------------ */
typedef struct {
    uint64_t     magic;
    uint32_t     version;
    uint32_t     num_regions;
    ckpt_regs_t  regs;           /* CPU state at ROI entry */
    uint64_t     roi_entry_rip;  /* RIP we want to jump to after restore */
    uint64_t     stack_va;       /* the stack VA we saved (for the loader) */
    uint8_t      padding[48];    /* reserved, must be zero */
} ckpt_header_t;

/* ------------------------------------------------------------------ */
/*  Convenience: total size of the descriptors block                    */
/* ------------------------------------------------------------------ */
#define CKPT_REGIONS_OFFSET  (sizeof(ckpt_header_t))
#define CKPT_DATA_OFFSET(n)  (CKPT_REGIONS_OFFSET + (n)*sizeof(ckpt_region_t))

#endif /* CHECKPOINT_H */
