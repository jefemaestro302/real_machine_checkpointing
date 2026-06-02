/**
 * libckpt.c - Generic LD_PRELOAD checkpoint library for gem5 SE mode
 *
 * Usage:
 *   # Trigger via SIGUSR1:
 *   LD_PRELOAD=./libckpt.so CKPT_OUTPUT=dump.ckpt ./your_app &
 *   kill -SIGUSR1 $!
 *
 *   # Trigger automatically after N seconds of wall time:
 *   CKPT_OUTPUT=dump.ckpt CKPT_AFTER_NS=5000000000 LD_PRELOAD=./libckpt.so ./your_app
 *
 *   # Trigger at entry of a specific function (by wrapping it):
 *   CKPT_OUTPUT=dump.ckpt CKPT_AT_SYMBOL=my_roi_function LD_PRELOAD=./libckpt.so ./your_app
 *
 * Only one checkpoint is ever taken (first signal/timer wins).
 *
 * Compilation:
 *   gcc -O2 -shared -fPIC -o libckpt.so src/libckpt.c src/dumper.c \
 *       -ldl -lpthread -Isrc
 *
 * NOTE: dumper.c must also be compiled with -fPIC for shared linking.
 *       The dumper_asm.S naked function is NOT used here; we use the
 *       libckpt_dump_now() inline-asm entry below instead.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <stdatomic.h>

#include "checkpoint.h"

/* ------------------------------------------------------------------ */
/*  Forward declarations from dumper.c                                  */
/* ------------------------------------------------------------------ */
int ckpt_dump_impl(const char *path, ckpt_regs_t *regs);

/* ------------------------------------------------------------------ */
/*  Global state                                                        */
/* ------------------------------------------------------------------ */
static atomic_int  g_dumped      = 0;   /* ensure only one dump */
static const char *g_output_path = NULL;
static uint64_t    g_after_ns    = 0;   /* 0 = disabled         */

/* ------------------------------------------------------------------ */
/*  Core dump entry: capture all GPRs here (position-independent)       */
/* ------------------------------------------------------------------ */
/*
 * We use a naked-ish approach: save all registers onto the stack,
 * build a ckpt_regs_t, then call ckpt_dump_impl.
 *
 * This is called from a signal handler or from the timer thread,
 * so it runs in a context where the registers are already the
 * application's registers (signal frame) or close enough.
 *
 * For signal delivery: the kernel saves the full register state in
 * the ucontext_t passed to the SA_SIGINFO handler — we read from there.
 */
static void do_dump_from_ucontext(ucontext_t *uc)
{
    if (atomic_exchange(&g_dumped, 1) != 0) return; /* already dumped */

    ckpt_regs_t regs = {0};

    /* Extract GPRs from the kernel-saved signal frame */
#ifdef __x86_64__
    regs.rax    = (uint64_t)uc->uc_mcontext.gregs[REG_RAX];
    regs.rbx    = (uint64_t)uc->uc_mcontext.gregs[REG_RBX];
    regs.rcx    = (uint64_t)uc->uc_mcontext.gregs[REG_RCX];
    regs.rdx    = (uint64_t)uc->uc_mcontext.gregs[REG_RDX];
    regs.rsi    = (uint64_t)uc->uc_mcontext.gregs[REG_RSI];
    regs.rdi    = (uint64_t)uc->uc_mcontext.gregs[REG_RDI];
    regs.rbp    = (uint64_t)uc->uc_mcontext.gregs[REG_RBP];
    regs.rsp    = (uint64_t)uc->uc_mcontext.gregs[REG_RSP];
    regs.r8     = (uint64_t)uc->uc_mcontext.gregs[REG_R8];
    regs.r9     = (uint64_t)uc->uc_mcontext.gregs[REG_R9];
    regs.r10    = (uint64_t)uc->uc_mcontext.gregs[REG_R10];
    regs.r11    = (uint64_t)uc->uc_mcontext.gregs[REG_R11];
    regs.r12    = (uint64_t)uc->uc_mcontext.gregs[REG_R12];
    regs.r13    = (uint64_t)uc->uc_mcontext.gregs[REG_R13];
    regs.r14    = (uint64_t)uc->uc_mcontext.gregs[REG_R14];
    regs.r15    = (uint64_t)uc->uc_mcontext.gregs[REG_R15];
    regs.rip    = (uint64_t)uc->uc_mcontext.gregs[REG_RIP];
    regs.rflags = (uint64_t)uc->uc_mcontext.gregs[REG_EFL];
    regs.cs     = (uint64_t)uc->uc_mcontext.gregs[REG_CSGSFS] & 0xFFFF;
    regs.gs     = (uint64_t)(uc->uc_mcontext.gregs[REG_CSGSFS] >> 16) & 0xFFFF;
    regs.fs     = (uint64_t)(uc->uc_mcontext.gregs[REG_CSGSFS] >> 32) & 0xFFFF;

    /* FS/GS base via arch_prctl */
    syscall(158 /*arch_prctl*/, 0x1003 /*ARCH_GET_FS*/, &regs.fs_base);
    syscall(158 /*arch_prctl*/, 0x1004 /*ARCH_GET_GS*/, &regs.gs_base);
#else
#  error "libckpt only supports x86-64"
#endif

    fprintf(stderr, "[libckpt] Dumping checkpoint to: %s\n", g_output_path);
    fprintf(stderr, "[libckpt] RIP=0x%lx  RSP=0x%lx\n", regs.rip, regs.rsp);

    int rc = ckpt_dump_impl(g_output_path, &regs);
    if (rc != 0)
        fprintf(stderr, "[libckpt] ERROR: ckpt_dump_impl returned %d\n", rc);
    else
        fprintf(stderr, "[libckpt] Done!\n");
}

/* ------------------------------------------------------------------ */
/*  SIGUSR1 signal handler                                              */
/* ------------------------------------------------------------------ */
static void sigusr1_handler(int sig, siginfo_t *info, void *ctx)
{
    (void)sig; (void)info;
    do_dump_from_ucontext((ucontext_t *)ctx);
}

/* ------------------------------------------------------------------ */
/*  Timer thread: dump after CKPT_AFTER_NS nanoseconds                  */
/* ------------------------------------------------------------------ */
static void *timer_thread(void *arg)
{
    (void)arg;
    struct timespec ts = {
        .tv_sec  = (time_t)(g_after_ns / 1000000000ULL),
        .tv_nsec = (long)  (g_after_ns % 1000000000ULL),
    };
    nanosleep(&ts, NULL);

    if (atomic_load(&g_dumped)) return NULL;

    /* Send SIGUSR1 to ourselves so we capture via signal frame */
    raise(SIGUSR1);
    return NULL;
}

/* ------------------------------------------------------------------ */
/*  Constructor: run at .so load time                                   */
/* ------------------------------------------------------------------ */
__attribute__((constructor))
static void libckpt_init(void)
{
    /* Read config from environment */
    g_output_path = getenv("CKPT_OUTPUT");
    if (!g_output_path) g_output_path = "libckpt_dump.ckpt";

    const char *after_str = getenv("CKPT_AFTER_NS");
    if (after_str) g_after_ns = (uint64_t)strtoull(after_str, NULL, 10);

    /* Install SIGUSR1 handler */
    struct sigaction sa = {0};
    sa.sa_flags     = SA_SIGINFO | SA_RESTART;
    sa.sa_sigaction = sigusr1_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR1, &sa, NULL);

    fprintf(stderr, "[libckpt] Initialized. Output=%s  AfterNs=%lu\n",
            g_output_path, (unsigned long)g_after_ns);
    fprintf(stderr, "[libckpt] Send SIGUSR1 to PID %d to trigger dump.\n",
            (int)getpid());

    /* Optionally launch timer thread */
    if (g_after_ns > 0) {
        pthread_t tid;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&tid, &attr, timer_thread, NULL);
        pthread_attr_destroy(&attr);
        fprintf(stderr, "[libckpt] Timer set for %lu ns.\n",
                (unsigned long)g_after_ns);
    }
}
