/**
 * target_app.c - Proof-of-concept "Tailbench-like" target application
 *
 * This simulates a Tailbench workload with:
 *  - A slow initialization phase (pre-ROI)
 *  - A Region of Interest (ROI) where real computation happens
 *  - Call to ckpt_dump() at the ROI boundary
 *
 * On FIRST run: does the init, dumps checkpoint at ROI entry, then runs ROI.
 * On RESTORED run (via loader): jumps directly to ROI, skipping init.
 *
 * Compilation:
 *   gcc -O2 -static -no-pie -fno-stack-protector \
 *       -o target_app target_app.c dumper.c
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <time.h>

#include "dumper.h"

/* ------------------------------------------------------------------ */
/*  Simulated workload data structures                                  */
/* ------------------------------------------------------------------ */

#define TABLE_SIZE   (1 << 20)   /* 1M entries, ~8 MB */
#define NUM_QUERIES  100

typedef struct {
    uint64_t key;
    uint64_t value;
} entry_t;

/* Global lookup table (simulates a pre-built index) */
static entry_t g_table[TABLE_SIZE];
static int     g_table_ready = 0;

/* Query set (simulates incoming requests) */
static uint64_t g_queries[NUM_QUERIES];

/* ------------------------------------------------------------------ */
/*  INIT PHASE - expensive, should NOT be in ROI                        */
/* ------------------------------------------------------------------ */
static void slow_initialization(void)
{
    fprintf(stderr, "[target] === INIT PHASE START ===\n");
    fprintf(stderr, "[target] Building lookup table (%zu MB)...\n",
            TABLE_SIZE * sizeof(entry_t) / (1024*1024));

    /* Simulate expensive init: fill the hash table */
    for (size_t i = 0; i < TABLE_SIZE; i++) {
        g_table[i].key   = i * 6364136223846793005ULL + 1442695040888963407ULL;
        g_table[i].value = g_table[i].key ^ (g_table[i].key >> 33);
    }

    /* Prepare queries */
    for (int i = 0; i < NUM_QUERIES; i++) {
        g_queries[i] = (uint64_t)i * 999983ULL;
    }

    g_table_ready = 1;
    fprintf(stderr, "[target] === INIT PHASE DONE ===\n");
}

/* ------------------------------------------------------------------ */
/*  ROI PHASE - what we want to simulate in gem5                        */
/* ------------------------------------------------------------------ */

/* Simple hash lookup to simulate serving a request */
static uint64_t serve_request(uint64_t query)
{
    size_t idx = query % TABLE_SIZE;
    uint64_t result = 0;

    /* Walk 16 steps (simulates cache-unfriendly traversal) */
    for (int step = 0; step < 16; step++) {
        result ^= g_table[idx].value;
        idx = (idx + g_table[idx].key) % TABLE_SIZE;
    }
    return result;
}

static void roi_phase(void)
{
    /* Truly minimal ROI: raw write syscall, no libc function calls.
     * This proves the restore mechanism without any stack-heavy libc calls. */
    const char start_msg[] = "[target] === ROI PHASE START ===\n";
    (void)syscall(1 /* SYS_write */, 2, start_msg, sizeof(start_msg)-1);

    if (!g_table_ready) {
        const char err[] = "[target] ERROR: table not initialized!\n";
        (void)syscall(1, 2, err, sizeof(err)-1);
        syscall(60 /* SYS_exit */, 1);
    }

    uint64_t total = 0;
    for (int i = 0; i < NUM_QUERIES; i++) {
        total += serve_request(g_queries[i]);
    }

    /* Format output using only stack-local data and raw write */
    char buf[80];
    /* Simple hex formatting without printf */
    const char prefix[] = "[target] checksum=0x";
    const char suffix[] = "\n";
    char hexval[17];
    hexval[16] = '\0';
    uint64_t v = total;
    for (int j = 15; j >= 0; j--) {
        uint8_t nib = v & 0xf;
        hexval[j] = (nib < 10) ? ('0' + nib) : ('a' + nib - 10);
        v >>= 4;
    }
    (void)syscall(1, 2, prefix, sizeof(prefix)-1);
    (void)syscall(1, 2, hexval, 16);
    (void)syscall(1, 2, suffix, 1);

    const char done_msg[] = "[target] === ROI PHASE DONE ===\n";
    (void)syscall(1, 2, done_msg, sizeof(done_msg)-1);
    (void)buf;
}

/* ================================================================== */
/*  Main                                                                 */
/* ================================================================== */
int main(int argc, char *argv[])
{
    fprintf(stderr, "[target] PID=%d\n", getpid());

    /* ---- INIT (pre-ROI) ---- */
    slow_initialization();

    /* ---- CHECKPOINT at ROI ENTRY ----
     *
     * IMPORTANT: We push RSP down by 64KB before calling ckpt_dump().
     * This ensures the saved RSP has ~64KB of headroom above it for the
     * ROI's stack usage when restored.
     *
     * In gem5/Tailbench, this call site is equivalent to the ROI entry
     * marker (e.g., after tailbench warmup finishes).
     */
    fprintf(stderr, "[target] Dumping checkpoint at ROI boundary...\n");

    const char *dump_path = (argc > 1) ? argv[1] : "dump.ckpt";

    /* Reserve stack space so the saved RSP has room for the ROI's frames */
    volatile char stack_guard[65536];
    stack_guard[0] = 0;  /* touch it to ensure it's allocated */
    (void)stack_guard;

    if (ckpt_dump(dump_path) < 0) {
        fprintf(stderr, "[target] WARNING: checkpoint dump failed, continuing\n");
    }


    /*
     * NOTE FOR GEM5 INTEGRATION:
     *
     * After ckpt_dump() returns we continue with the ROI normally.
     * In the gem5 scheduler, instead of running the app again from scratch,
     * you do:  execv("loader", ["loader", "dump.ckpt"])
     *
     * The loader will map all saved memory and jump directly to the
     * instruction after ckpt_dump() returns — exactly here.
     */

    /* ---- ROI (Region of Interest) ---- */
    roi_phase();

    const char exit_msg[] = "[target] Normal exit.\n";
    (void)syscall(1 /* SYS_write */, 2, exit_msg, sizeof(exit_msg)-1);
    
    /* Use raw exit syscall to avoid glibc teardown issues in restored context */
    syscall(60 /* SYS_exit */, 0);
    return 0;
}
