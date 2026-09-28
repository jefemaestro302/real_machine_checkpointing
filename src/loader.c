/**
 * loader.c - Custom static loader for checkpoint restore
 *
 * Usage:
 *   loader <dump.ckpt> [--native] [--barrier=FILE:N] [OLD_PREFIX=NEW_PREFIX ...]
 *
 *   --native          do not execute m5_exit (a gem5 pseudo-instruction that
 *                     is an illegal opcode, SIGILL, on real hardware). Use it
 *                     to test a checkpoint on the host.
 *   --barrier=FILE:N  SMT-N runs: every loader appends one byte to FILE after
 *                     restoring and waits until FILE holds N bytes, so that
 *                     all threads reach the ROI boundary (m5_exit) together.
 *   OLD=NEW           reopen checkpointed files whose path starts with the
 *                     path component(s) OLD from NEW instead.
 *
 * Key architectural insight:
 *   - Loader .text:   0x20000000+ (via -Wl,-Ttext-segment=0x20000000)
 *   - Target app:     0x400000+ (from dump, application-dependent)
 *   - Target stack:   restored at its original checkpoint address
 *
 * The loader's .text is NEVER clobbered by the restore: before touching
 * anything, main() checks that no checkpointed region overlaps the loader
 * image and heap, the scratch page or the mapped checkpoint file, and
 * aborts with a clear message otherwise.
 * The loader's STACK (originally high, from execve) IS clobbered when we
 * restore the target's stack region.
 *
 * Solution: switch to a scratch stack at SCRATCH_VA (0x7E0000000000) BEFORE
 * the restore loop, then do all restores on the scratch stack. Unlike
 * earlier revisions of this file, no ucontext_t/setcontext() is involved
 * anymore: the restore_ctx_t is built directly in the scratch page and the
 * CPU state is loaded with raw assembly.
 *
 * Flow:
 *  main():
 *    1. Read the header and mmap() the whole checkpoint at an address that
 *       no checkpointed region uses (the payload is not copied to the heap)
 *    2. Validate the file (offsets/sizes inside the file) and the layout
 *       (no region overlaps loader-owned memory)
 *    3. Restore file descriptors (reopen + dup2 + lseek, with optional
 *       path remapping supplied via argv as OLD_PREFIX=NEW_PREFIX)
 *    4. Allocate the scratch page (SCRATCH_VA): restore_ctx_t, a copy of
 *       the final trampoline, and the scratch stack
 *    5. switch_stack_and_restore(ctx, scratch_stack_top)
 *       v (now on scratch stack)
 *    6. restore_and_jump(ctx):
 *         - grow the program break up to the target heap end when the
 *           heap lies above the loader's break (see "Program break")
 *         - munmap + mmap(MAP_FIXED) + memcpy + mprotect for each region
 *         - the target's [vdso] functions are patched into plain syscalls
 *           (the copied host vDSO reads a frozen [vvar] page and host TSC
 *           parameters, so it would return a stuck/garbage clock in gem5)
 *         - optional SMT barrier
 *         - arch_prctl(ARCH_SET_FS) to restore TLS
 *         - fxrstor from ckpt_regs_t.fpregs restores the FPU/SSE state
 *         - jump to the trampoline copy in the scratch page, which
 *             0) munmaps the checkpoint file,
 *             a) moves the program break to the target's heap end when it
 *                lies below the loader's (see fix_brk below),
 *             b) executes m5_exit(0): gem5-only pseudo-instruction marking
 *                the ROI boundary, so the simulation script can reset stats
 *                and switch to a detailed CPU model before the target
 *                resumes (skipped with --native),
 *             c) restores RFLAGS on the scratch stack, then the GPRs and
 *                %rsp, and jumps to the checkpointed RIP through memory.
 *           Nothing is ever pushed on the restored stack: the interrupted
 *           code may keep live data in the 128-byte red zone below %rsp.
 *
 * Compilation:
 *   gcc -O2 -static -no-pie -fno-stack-protector \
 *       -Wl,-Ttext-segment=0x20000000 -o loader loader.c
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <elf.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <sys/auxv.h>
#include <signal.h>

#include "checkpoint.h"

#ifndef __x86_64__
#error "This loader is x86-64 only"
#endif

/* ------------------------------------------------------------------ */
/*  Logging helpers (raw write syscall, no buffering, stack-minimal)    */
/* ------------------------------------------------------------------ */
void my_memset(void *s, int c, size_t n) {
    unsigned char *p = s;
    while (n--) {
        *p++ = (unsigned char)c;
    }
}

static inline void log_str(const char *s)
{
    size_t n = 0;
    while (s[n]) n++;
    if (write(STDERR_FILENO, s, n) < 0) { /* nothing useful to do */ }
}

static void log_hex64(uint64_t v)
{
    char buf[19] = "0x";
    for (int i = 17; i >= 2; i--) {
        uint8_t nib = v & 0xf;
        buf[i] = (nib < 10) ? '0' + nib : 'a' + nib - 10;
        v >>= 4;
    }
    buf[18] = '\0';
    char *p = buf + 2;
    while (p[0] == '0' && p[1]) p++;
    size_t len = (size_t)(&buf[18] - p);
    if (write(STDERR_FILENO, "0x", 2) < 0 ||
        write(STDERR_FILENO, p, len ? len : 1) < 0) { /* ignore */ }
}

#define DIE(msg)  do { log_str("[loader] FATAL: " msg "\n"); _Exit(1); } while(0)
#define LOG(msg)  do { log_str("[loader] " msg "\n"); } while(0)

/* ------------------------------------------------------------------ */
/*  Exact-read helper                                                    */
/* ------------------------------------------------------------------ */
static ssize_t read_exact(int fd, void *buf, size_t n)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = read(fd, (char *)buf + done, n - done);
        if (r <= 0) return r == 0 ? (ssize_t)done : -1;
        done += (size_t)r;
    }
    return (ssize_t)done;
}

/* ------------------------------------------------------------------ */
/*  Final trampoline                                                     */
/*                                                                       */
/*  Position-independent code that is COPIED into the scratch page and   */
/*  executed from there, because moving the program break down (fix_brk) */
/*  unmaps the loader's own image. Its data slots live inside the copied */
/*  range and are addressed %rip-relative, so they stay valid in the     */
/*  copy. On entry %rax = &ckpt_regs_t (in the scratch page) and %rsp is */
/*  on the scratch stack.                                                */
/* ------------------------------------------------------------------ */
extern const char rmc_tramp_start[], rmc_tramp_end[];
extern const char rmc_tramp_brk[], rmc_tramp_m5[], rmc_tramp_rip[];
extern const char rmc_tramp_ckpt[], rmc_tramp_ckpt_len[];

__asm__ (
    "    .text\n"
    "    .balign 16\n"
    "    .globl rmc_tramp_start, rmc_tramp_end\n"
    "    .globl rmc_tramp_brk, rmc_tramp_m5, rmc_tramp_rip\n"
    "    .globl rmc_tramp_ckpt, rmc_tramp_ckpt_len\n"
    "rmc_tramp_start:\n"
    /* 0) munmap(checkpoint): the target gets a clean address space */
    "    movq  rmc_tramp_ckpt(%rip), %rdi\n"
    "    testq %rdi, %rdi\n"
    "    jz    0f\n"
    "    movq  %rax, %r12\n"
    "    movq  rmc_tramp_ckpt_len(%rip), %rsi\n"
    "    movl  $11, %eax\n"                     /* SYS_munmap */
    "    syscall\n"
    "    movq  %r12, %rax\n"
    "0:\n"
    /* a) brk(target_heap_end), if requested */
    "    movq  rmc_tramp_brk(%rip), %rdi\n"
    "    testq %rdi, %rdi\n"
    "    jz    1f\n"
    "    movq  %rax, %r12\n"
    "    movl  $12, %eax\n"                     /* SYS_brk */
    "    syscall\n"
    "    movq  %r12, %rax\n"
    "1:\n"
    /* b) m5_exit(0): ROI boundary (skipped with --native) */
    "    cmpq  $0, rmc_tramp_m5(%rip)\n"
    "    je    2f\n"
    "    movq  %rax, %r12\n"
    "    xorl  %edi, %edi\n"
    "    xorl  %esi, %esi\n"
    "    .byte 0x0f, 0x04\n"
    "    .word 0x21\n"                          /* m5_exit */
    "    movq  %r12, %rax\n"
    "2:\n"
    /* c) RFLAGS via the scratch stack, then GPRs, then %rsp, then jump.
     *    mov does not modify flags, so RFLAGS survives until the jmp. */
    "    pushq 0x88(%rax)\n"
    "    popfq\n"
    "    movq  0x38(%rax), %rsp\n"
    "    movq  0x78(%rax), %r15\n"
    "    movq  0x70(%rax), %r14\n"
    "    movq  0x68(%rax), %r13\n"
    "    movq  0x60(%rax), %r12\n"
    "    movq  0x58(%rax), %r11\n"
    "    movq  0x50(%rax), %r10\n"
    "    movq  0x48(%rax), %r9\n"
    "    movq  0x40(%rax), %r8\n"
    "    movq  0x30(%rax), %rbp\n"
    "    movq  0x28(%rax), %rdi\n"
    "    movq  0x20(%rax), %rsi\n"
    "    movq  0x18(%rax), %rdx\n"
    "    movq  0x10(%rax), %rcx\n"
    "    movq  0x08(%rax), %rbx\n"
    "    movq  0x00(%rax), %rax\n"
    "    jmp   *rmc_tramp_rip(%rip)\n"
    "    .balign 8\n"
    "rmc_tramp_brk: .quad 0\n"
    "rmc_tramp_m5:  .quad 0\n"
    "rmc_tramp_rip: .quad 0\n"
    "rmc_tramp_ckpt: .quad 0\n"
    "rmc_tramp_ckpt_len: .quad 0\n"
    "rmc_tramp_end:\n"
);

/* ------------------------------------------------------------------ */
/*  Scratch page layout                                                  */
/*                                                                       */
/*  SCRATCH_VA        +-----------------------------------------------+ */
/*  (0x7E0000000000)  | restore_ctx_t (num_regions, ckpt_data*,       | */
/*                    | descs*, fs_base, barrier, regs)               | */
/*  + TRAMP_OFF       | copy of rmc_tramp_start..rmc_tramp_end        | */
/*                    +-----------------------------------------------+ */
/*  + STACK_OFF       | Scratch stack (grows downward from top)       | */
/*                    +-----------------------------------------------+ */
/* ------------------------------------------------------------------ */
#define SCRATCH_VA     ((void *)0x7E0000000000ULL)
#define SCRATCH_SZ     (131072)                  /* 128 KB, plenty   */
#define SCRATCH_TRAMP_OFF (0x2000)
#define SCRATCH_STACK_OFF (SCRATCH_SZ)           /* top of scratch   */

/* Parameters for the restore stage, stored in the scratch page */
typedef struct {
    uint32_t       num_regions;
    uint32_t       barrier_n;     /* SMT barrier: number of loaders (0 = off) */
    void          *ckpt_data;     /* mmap'd checkpoint file             */
    ckpt_region_t *descs;         /* region descriptors (inside ckpt_data) */
    uint64_t       fs_base;       /* TLS fs_base to restore             */
    char          *tramp;         /* trampoline copy in the scratch page */
    uint64_t       brk_grow;      /* gem5: brk() up to here before restoring */
    uint64_t       heap_start;    /* target [heap], for --native prctl   */
    uint64_t       heap_end;
    uint32_t       native;
    char           barrier_path[512];
    ckpt_regs_t    regs;
} restore_ctx_t;

_Static_assert(sizeof(restore_ctx_t) <= SCRATCH_TRAMP_OFF,
               "restore_ctx_t overlaps the trampoline copy");

/* ------------------------------------------------------------------ */
/*  vDSO patching                                                        */
/*                                                                       */
/*  The target's libc keeps pointers into its [vdso]. The copied vDSO     */
/*  code computes time from the copied [vvar] page (frozen at dump time)  */
/*  plus the TSC, so after restore clock_gettime() & co. return a stuck   */
/*  or meaningless clock. Each exported entry point is overwritten with   */
/*  "mov $NR, %eax; syscall; ret" (8 bytes): same arguments, same return */
/*  convention, and gem5 SE implements all these syscalls.               */
/* ------------------------------------------------------------------ */
static const struct { const char *name; uint32_t nr; } vdso_syscalls[] = {
    { "clock_gettime",  228 }, { "__vdso_clock_gettime", 228 },
    { "gettimeofday",    96 }, { "__vdso_gettimeofday",   96 },
    { "time",           201 }, { "__vdso_time",          201 },
    { "clock_getres",   229 }, { "__vdso_clock_getres",  229 },
    { "getcpu",         309 }, { "__vdso_getcpu",        309 },
    /* vgetrandom(buf, len, flags, state, state_len): the first three
     * arguments match getrandom(2); glibc falls back cleanly if the
     * extra state is never initialised. */
    { "__vdso_getrandom", 318 },
};

static int str_eq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static void patch_vdso(uint8_t *base, size_t size)
{
    Elf64_Ehdr *eh = (Elf64_Ehdr *)base;
    if (size < sizeof(*eh) ||
        eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' ||
        eh->e_ident[2] != 'L'  || eh->e_ident[3] != 'F') {
        LOG("WARNING: [vdso] is not an ELF image, not patched");
        return;
    }
    if (eh->e_shoff == 0 ||
        eh->e_shoff + (uint64_t)eh->e_shnum * sizeof(Elf64_Shdr) > size) {
        LOG("WARNING: [vdso] section headers not mapped, not patched");
        return;
    }

    /* Link-time vaddr of the first PT_LOAD: symbol values are relative to it */
    uint64_t load_vaddr = 0;
    Elf64_Phdr *ph = (Elf64_Phdr *)(base + eh->e_phoff);
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type == PT_LOAD) { load_vaddr = ph[i].p_vaddr & ~0xfffULL; break; }
    }

    Elf64_Shdr *sh = (Elf64_Shdr *)(base + eh->e_shoff);
    int patched = 0;
    for (int i = 0; i < eh->e_shnum; i++) {
        if (sh[i].sh_type != SHT_DYNSYM) continue;
        if (sh[i].sh_link >= eh->e_shnum) break;
        Elf64_Shdr *strh = &sh[sh[i].sh_link];
        if (sh[i].sh_offset + sh[i].sh_size > size ||
            strh->sh_offset + strh->sh_size > size) break;
        Elf64_Sym  *syms = (Elf64_Sym *)(base + sh[i].sh_offset);
        const char *strs = (const char *)(base + strh->sh_offset);
        size_t nsyms = sh[i].sh_size / sizeof(Elf64_Sym);

        for (size_t s = 0; s < nsyms; s++) {
            if (ELF64_ST_TYPE(syms[s].st_info) != STT_FUNC) continue;
            if (syms[s].st_name >= strh->sh_size) continue;
            const char *nm = strs + syms[s].st_name;
            for (size_t k = 0; k < sizeof(vdso_syscalls) / sizeof(vdso_syscalls[0]); k++) {
                if (!str_eq(nm, vdso_syscalls[k].name)) continue;
                uint64_t off = syms[s].st_value - load_vaddr;
                if (off + 8 > size) break;
                uint8_t *p = base + off;
                uint32_t nr = vdso_syscalls[k].nr;
                p[0] = 0xb8;                       /* mov $nr, %eax */
                p[1] = nr & 0xff; p[2] = (nr >> 8) & 0xff;
                p[3] = (nr >> 16) & 0xff; p[4] = (nr >> 24) & 0xff;
                p[5] = 0x0f; p[6] = 0x05;          /* syscall       */
                p[7] = 0xc3;                       /* ret           */
                patched++;
                break;
            }
        }
    }
    log_str("[loader] [vdso] entry points redirected to syscalls: ");
    log_hex64((uint64_t)patched);
    log_str("\n");
}

/* ------------------------------------------------------------------ */
/*  SMT barrier (runs after the restore, on the scratch stack)          */
/* ------------------------------------------------------------------ */
static void smt_barrier(restore_ctx_t *ctx)
{
    int bfd = open(ctx->barrier_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (bfd < 0) { LOG("WARNING: cannot open barrier file, not waiting"); return; }
    if (write(bfd, "x", 1) != 1) LOG("WARNING: barrier write failed");
    close(bfd);

    struct stat st;
    for (;;) {
        if (stat(ctx->barrier_path, &st) == 0 &&
            (uint64_t)st.st_size >= ctx->barrier_n)
            break;
        /* Keep the poll cheap: few syscalls, and the instructions spent
         * here by the last loaders bound the ROI skew between threads. */
        for (volatile int i = 0; i < 256; i++) { }
    }
    LOG("SMT barrier passed");
}

/* ------------------------------------------------------------------ */
/*  Stage 2: restore all regions, then jump (on scratch stack)          */
/*                                                                       */
/*  This function NEVER uses the loader's original stack.               */
/*  It runs entirely on the scratch stack (switched in stage-switch).   */
/* ------------------------------------------------------------------ */
__attribute__((noinline, noreturn, used))
static void restore_and_jump(restore_ctx_t *ctx)
{
    log_str("[loader] restore_and_jump: restoring regions\n");

    /* Target heap above the loader's break (PIE binaries): grow the break
     * up to the target heap end NOW, while [loader_brk, heap_end) is still
     * unmapped; the regions restored below simply split that range. */
    if (ctx->brk_grow) {
        uint64_t got = (uint64_t)syscall(SYS_brk, ctx->brk_grow);
        if (got != ctx->brk_grow)
            LOG("WARNING: could not grow the program break to the target heap end");
    }

    for (uint32_t i = 0; i < ctx->num_regions; i++) {
        ckpt_region_t *d = &ctx->descs[i];
        size_t sz = (size_t)(d->end - d->start);

        /* Skip vsyscall entirely */
        if (strstr(d->name, "[vsyscall]")) {
            continue;
        }

        if (d->flags & CKPT_FLAG_SKIP) continue;
        int prot = 0;
        if (d->prot & CKPT_PROT_R) prot |= PROT_READ;
        if (d->prot & CKPT_PROT_W) prot |= PROT_WRITE;
        if (d->prot & CKPT_PROT_X) prot |= PROT_EXEC;

        munmap((void *)(uintptr_t)d->start, sz);

        void *m = mmap((void *)(uintptr_t)d->start, sz,
                       PROT_READ | PROT_WRITE | PROT_EXEC,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                       -1, 0);
        if (m == MAP_FAILED || m != (void *)(uintptr_t)d->start) {
            log_str("[loader] mmap failed in restore_and_jump! start=");
            log_hex64(d->start);
            log_str(" sz=");
            log_hex64(sz);
            log_str("\n");
            DIE("cannot recreate a checkpointed region");
        }
        if (d->data_size > 0) {
            memcpy(m, (char *)ctx->ckpt_data + d->file_offset, (size_t)d->data_size);
        }
        if (str_eq(d->name, "[vdso]")) {
            patch_vdso((uint8_t *)m, sz);
        }
        mprotect(m, sz, prot);
    }

    /* --native: Linux refuses to move the break below start_brk, and may
     * refuse a huge brk_grow (overcommit). PR_SET_MM can do it instead
     * (needs CAP_SYS_RESOURCE, as in CRIU). The two orders keep
     * start_brk <= brk valid at every step. */
    if (ctx->native && ctx->heap_end &&
        (uint64_t)syscall(SYS_brk, 0) != ctx->heap_end) {
        int ok = (prctl(PR_SET_MM, PR_SET_MM_BRK, ctx->heap_end, 0, 0) == 0 &&
                  prctl(PR_SET_MM, PR_SET_MM_START_BRK, ctx->heap_start, 0, 0) == 0) ||
                 (prctl(PR_SET_MM, PR_SET_MM_START_BRK, ctx->heap_start, 0, 0) == 0 &&
                  prctl(PR_SET_MM, PR_SET_MM_BRK, ctx->heap_end, 0, 0) == 0);
        if (!ok)
            LOG("WARNING: --native could not move the program break (needs "
                "CAP_SYS_RESOURCE); malloc may fail once the heap grows or shrinks");
    }

    if (ctx->barrier_n > 1) smt_barrier(ctx);

    log_str("[loader] Setting FS base and jumping to ROI\n");
    if (ctx->fs_base) {
        syscall(158, 0x1002, ctx->fs_base);
    }

    ckpt_regs_t *r = &ctx->regs;
    if (r->fpregs_size > 0) {
        __asm__ volatile("fxrstor %0" : : "m" (r->fpregs));
    }

    /* Continue in the trampoline copy (brk fix, m5_exit, register restore) */
    __asm__ volatile (
        "jmp *%1\n\t"
        :
        : "a"(r), "r"(ctx->tramp)
        : "memory"
    );
    __builtin_unreachable();
}

/* ------------------------------------------------------------------ */
/*  Stage switch: switch rsp to scratch_top, call restore_and_jump      */
/*  with ctx as the argument.                                            */
/*                                                                       */
/*  We use naked-asm to avoid touching the old stack at all.            */
/* ------------------------------------------------------------------ */
__attribute__((noinline, noreturn))
static void switch_stack_and_restore(restore_ctx_t *ctx, void *scratch_top)
{
    __asm__ volatile (
        /* rdi = ctx (already set by calling convention)
         * rsi = scratch_top */
        "movq %1, %%rsp\n\t"         /* switch stack */
        "subq $128, %%rsp\n\t"       /* red zone guard */
        "andq $-16, %%rsp\n\t"       /* align */
        "movq %0, %%rdi\n\t"         /* arg0 = ctx */
        "callq restore_and_jump\n\t" /* this never returns */
        "ud2\n\t"
        :
        : "r"(ctx), "r"(scratch_top)
        : "memory"
    );
    __builtin_unreachable();
}

/* ------------------------------------------------------------------ */
/*  Layout validation helpers                                            */
/* ------------------------------------------------------------------ */
static int restored(const ckpt_region_t *d)
{
    return !(d->flags & CKPT_FLAG_SKIP) && !strstr(d->name, "[vsyscall]");
}

/* Index of the first restored region intersecting [lo, hi), or -1 */
static long find_overlap(const ckpt_region_t *descs, uint32_t n,
                         uint64_t lo, uint64_t hi)
{
    for (uint32_t i = 0; i < n; i++) {
        if (!restored(&descs[i])) continue;
        if (descs[i].start < hi && lo < descs[i].end) return (long)i;
    }
    return -1;
}

static void die_overlap(const ckpt_region_t *d, const char *what)
{
    log_str("[loader] FATAL: checkpointed region ");
    log_hex64(d->start);
    log_str("-");
    log_hex64(d->end);
    log_str(" (");
    log_str(d->name);
    log_str(") overlaps ");
    log_str(what);
    log_str("\n");
    _Exit(1);
}

/* Remap cfd_path through the OLD=NEW arguments. OLD must match whole
 * path components ("/a/b=/x" rewrites "/a/b" and "/a/b/f", not "/a/bc"). */
static const char *remap_path(const char *path, char **remaps, int nremaps)
{
    for (int j = 0; j < nremaps; j++) {
        const char *eq = strchr(remaps[j], '=');
        size_t old_len = (size_t)(eq - remaps[j]);
        if (strncmp(path, remaps[j], old_len) != 0) continue;
        if (path[old_len] != '\0' && path[old_len] != '/' &&
            !(old_len > 0 && remaps[j][old_len - 1] == '/'))
            continue;
        const char *rest = path + old_len;
        char *out = malloc(strlen(eq + 1) + strlen(rest) + 1);
        if (!out) DIE("OOM remap");
        strcpy(out, eq + 1);
        strcat(out, rest);
        return out;
    }
    return path;
}

static int is_regular_file_path(const char *p)
{
    struct stat st;
    return p[0] == '/' && strncmp(p, "/dev/", 5) != 0 &&
           strncmp(p, "/proc/", 6) != 0 &&
           stat(p, &st) == 0 && S_ISREG(st.st_mode);
}

/* ------------------------------------------------------------------ */
/*  File descriptor restore                                              */
/* ------------------------------------------------------------------ */
static void restore_fds(const ckpt_fd_t *fds, uint32_t num_fds,
                        char **remaps, int nremaps)
{
    for (uint32_t i = 0; i < num_fds; i++) {
        const ckpt_fd_t *cfd = &fds[i];
        int acc = cfd->flags & O_ACCMODE;
        const char *path = remap_path(cfd->path, remaps, nremaps);
        int regular = is_regular_file_path(path);
        int target_fd;

        if (cfd->fd >= 0 && cfd->fd <= 2) {
            /* stdin/stdout/stderr stay connected to the simulator's own,
             * EXCEPT a stdin redirected from a file (e.g. "bwaves < in"),
             * whose contents and read offset the program depends on. */
            if (!(regular && acc == O_RDONLY)) continue;
        }

        if (acc == O_WRONLY) {
            /* Output files: sinkholed, the ROI must not clobber results */
            target_fd = open("/dev/null", O_WRONLY);
        } else if (!regular) {
            log_str("[loader] WARNING: fd ");
            log_hex64((uint64_t)cfd->fd);
            log_str(" is not a regular file, not restored: ");
            log_str(path);
            log_str("\n");
            continue;
        } else {
            if (acc == O_RDWR) {
                log_str("[loader] WARNING: fd ");
                log_hex64((uint64_t)cfd->fd);
                log_str(" reopened read-write, the simulation may modify ");
                log_str(path);
                log_str(" (remap it to a copy with OLD=NEW)\n");
            }
            target_fd = open(path, cfd->flags & ~(O_CREAT | O_TRUNC | O_EXCL));
        }

        if (target_fd < 0) {
            log_str("[loader] WARNING: failed to restore fd ");
            log_hex64((uint64_t)cfd->fd);
            log_str(": ");
            log_str(path);
            log_str("\n");
            continue;
        }
        if (target_fd != cfd->fd) {
            if (dup2(target_fd, cfd->fd) < 0) {
                log_str("[loader] WARNING: dup2 failed for fd ");
                log_hex64((uint64_t)cfd->fd);
                log_str("\n");
                close(target_fd);
                continue;
            }
            close(target_fd);
        }
        if (acc != O_WRONLY && lseek(cfd->fd, cfd->offset, SEEK_SET) < 0) {
            log_str("[loader] WARNING: lseek failed for fd ");
            log_hex64((uint64_t)cfd->fd);
            log_str("\n");
        }
    }
}

/* ------------------------------------------------------------------ */
/*  Program-break anchor (build/loader_pie)                              */
/*                                                                       */
/*  The initial break of a static binary is the end of its highest       */
/*  segment. build/loader ends at ~0x200xxxxx, right for non-PIE targets */
/*  (heap below it: moving the break is a cheap shrink). For PIE targets */
/*  (heap at 0x5555_xxxx_xxxx) the break would have to grow ~85 TiB and  */
/*  gem5 checks such a range page by page (minutes). build/loader_pie    */
/*  adds this page at 0x555500000000 (Makefile: --section-start), just   */
/*  below where Linux loads PIE executables, so the grow is ~1 GiB.      */
/* ------------------------------------------------------------------ */
#ifdef RMC_BRK_ANCHOR
__attribute__((section(".rmc_brk_anchor"), used, aligned(4096)))
static char rmc_brk_anchor[4096] = { 1 };
#endif

/* Moving the break further than this is refused: gem5's cost is linear
 * in the distance (2 TiB ~ 5e8 page checks, seconds), and past it the
 * other loader build is the right tool. 2 TiB covers ASLR'd PIE bases. */
#define MAX_BRK_MOVE (2ULL << 40)

/* Loader-owned ranges: own PT_LOAD segments plus the loader heap */
static int loader_overlap(const ckpt_region_t *descs, uint32_t n, uint64_t heap_hi)
{
    const Elf64_Phdr *ph = (const Elf64_Phdr *)getauxval(AT_PHDR);
    unsigned long phnum = getauxval(AT_PHNUM);
    uint64_t img_end = 0;
    long o;
    for (unsigned long i = 0; ph && i < phnum; i++) {
        if (ph[i].p_type != PT_LOAD) continue;
        uint64_t lo = ph[i].p_vaddr & ~0xfffULL;
        uint64_t hi = (ph[i].p_vaddr + ph[i].p_memsz + 0xfffULL) & ~0xfffULL;
        if (hi > img_end) img_end = hi;
        if ((o = find_overlap(descs, n, lo, hi)) >= 0)
            die_overlap(&descs[o], "the loader image (relink the loader elsewhere)");
    }
    if ((o = find_overlap(descs, n, img_end, heap_hi)) >= 0)
        die_overlap(&descs[o], "the loader heap (relink the loader elsewhere)");
    return 0;
}

/* ================================================================== */
/*  Main                                                                 */
/* ================================================================== */
int main(int argc, char *argv[])
{
    if (argc < 2) {
        log_str("Usage: loader <dump.ckpt> [--native] [--barrier=FILE:N] [OLD=NEW ...]\n");
        return 1;
    }

    /* ---- 0. Options ---- */
    int native = 0;
    const char *barrier = NULL;
    char **remaps = malloc(sizeof(char *) * (size_t)argc);
    int nremaps = 0;
    if (!remaps) DIE("OOM args");
    for (int j = 2; j < argc; j++) {
        if (strcmp(argv[j], "--native") == 0) native = 1;
        else if (strncmp(argv[j], "--barrier=", 10) == 0) barrier = argv[j] + 10;
        else if (strchr(argv[j], '=')) remaps[nremaps++] = argv[j];
        else {
            log_str("[loader] FATAL: unknown argument (remaps are OLD=NEW): ");
            log_str(argv[j]);
            log_str("\n");
            return 1;
        }
    }

    LOG("Opening checkpoint...");
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("loader: open"); return 1; }

    /* ---- 1. Read header ---- */
    ckpt_header_t hdr;
    if (read_exact(fd, &hdr, sizeof(hdr)) != sizeof(hdr)) DIE("Header read");
    if (hdr.magic != CKPT_MAGIC)     DIE("Bad magic");
    if (hdr.version != CKPT_VERSION) DIE("Version mismatch (regenerate the checkpoint)");

    log_str("[loader] ROI RIP=");
    log_hex64(hdr.roi_entry_rip);
    log_str("  RSP=");
    log_hex64(hdr.regs.rsp);
    log_str("\n");

    struct stat st;
    if (fstat(fd, &st) < 0) { perror("loader: fstat"); return 1; }
    uint64_t file_size = (uint64_t)st.st_size;
    uint64_t data_off = CKPT_DATA_OFFSET((uint64_t)hdr.num_regions, (uint64_t)hdr.num_fds);
    if (data_off > file_size) DIE("Truncated checkpoint (descriptors)");

    /* ---- 1b. Region descriptors (temporary copy to plan the layout) ---- */
    size_t desc_sz = hdr.num_regions * sizeof(ckpt_region_t);
    ckpt_region_t *tmp_descs = malloc(desc_sz);
    if (!tmp_descs) DIE("OOM descs");
    if (read_exact(fd, tmp_descs, desc_sz) != (ssize_t)desc_sz) DIE("Descs read");

    uint64_t heap_start = 0, heap_end = 0;
    for (uint32_t i = 0; i < hdr.num_regions; i++) {
        if ((tmp_descs[i].flags & CKPT_FLAG_HEAP) && tmp_descs[i].end > heap_end) {
            heap_start = tmp_descs[i].start;
            heap_end   = tmp_descs[i].end;
        }
    }

    /* ---- 1c. mmap the checkpoint where no checkpointed region lives.
     * A plain mmap(NULL) lands right below gem5's mmap_end (0x7ffff7fff000),
     * which is where the host placed the target's shared libraries: the
     * restore loop would then unmap its own source data. It must also stay
     * above the target heap, because the break may be grown up to it. ---- */
    uint64_t map_len = (file_size + 0xfffULL) & ~0xfffULL;
    uint64_t cur_brk = (uint64_t)(uintptr_t)sbrk(0);
    uint64_t above = heap_end > cur_brk ? heap_end : cur_brk;
    /* 16 TiB, or 1 TiB above the target heap / loader break, leaving the
     * target heap room to keep growing with brk() during the ROI. */
    uint64_t hint = 0x100000000000ULL;
    if (above + (1ULL << 40) > hint)
        hint = (above + (1ULL << 40) + 0x3fffffffULL) & ~0x3fffffffULL;
    for (;;) {
        long o = find_overlap(tmp_descs, hdr.num_regions, hint, hint + map_len);
        if (o < 0) break;
        hint = (tmp_descs[o].end + 0x3fffffffULL) & ~0x3fffffffULL; /* next 1 GiB */
    }
    void *ckpt_data = mmap((void *)(uintptr_t)hint, map_len, PROT_READ, MAP_PRIVATE, fd, 0);
    if (ckpt_data == MAP_FAILED) { perror("loader: ckpt mmap"); return 1; }
    close(fd);
    free(tmp_descs);

    ckpt_region_t *descs = (ckpt_region_t *)((char *)ckpt_data + CKPT_REGIONS_OFFSET);
    const ckpt_fd_t *fds = (const ckpt_fd_t *)((char *)ckpt_data +
                                               CKPT_FDS_OFFSET((uint64_t)hdr.num_regions));

    /* ---- 2. Validate payloads and layout ---- */
    for (uint32_t i = 0; i < hdr.num_regions; i++) {
        ckpt_region_t *d = &descs[i];
        log_str("[loader]   REGION ");
        log_hex64(d->start);
        log_str("-");
        log_hex64(d->end);
        log_str("  ");
        log_str(d->name);
        log_str("\n");
        if (d->end < d->start || d->data_size > d->end - d->start ||
            (d->data_size && (d->file_offset < data_off ||
                              d->file_offset + d->data_size > file_size)))
            DIE("Corrupt or truncated checkpoint (region payload out of the file)");
    }

    long o;
    loader_overlap(descs, hdr.num_regions,
                   (uint64_t)(uintptr_t)sbrk(0) + 0x100000 /* + malloc slack */);
    if ((o = find_overlap(descs, hdr.num_regions, (uint64_t)(uintptr_t)SCRATCH_VA,
                          (uint64_t)(uintptr_t)SCRATCH_VA + SCRATCH_SZ)) >= 0)
        die_overlap(&descs[o], "the loader scratch page");
    if ((o = find_overlap(descs, hdr.num_regions, (uint64_t)(uintptr_t)ckpt_data,
                          (uint64_t)(uintptr_t)ckpt_data + map_len)) >= 0)
        die_overlap(&descs[o], "the mapped checkpoint file");

    /* ---- 2b. Program break.
     * The kernel (or gem5) keeps the LOADER's break, while the restored libc
     * keeps using brk() on the TARGET's heap (its __curbrk). Left alone:
     *  - heap below the loader break (non-PIE): gem5 treats brk(heap_end+n)
     *    as a *shrink*, unmaps, returns success, and the ROI faults on the
     *    first fresh heap page;
     *  - heap above (PIE, e.g. SPEC): brk() fails, glibc stores the loader's
     *    break in __curbrk, and the next heap trim computes
     *    released = heap_top - loader_brk, corrupting the top chunk
     *    ("double free or corruption (out)").
     * So the break is moved to the target heap end: grown before the
     * restore (brk_grow) or shrunk from the trampoline (fix_brk), which
     * runs from the scratch page because the shrink unmaps the loader. */
    uint64_t fix_brk = 0, brk_grow = 0;
    cur_brk = (uint64_t)(uintptr_t)sbrk(0);
    if (!heap_end) {
        LOG("WARNING: no [heap] region in the checkpoint, program break left as is");
    } else if (heap_end < cur_brk && cur_brk - heap_end > MAX_BRK_MOVE) {
        LOG("WARNING: target heap far below the loader break, program break left as is: "
            "restore this (non-PIE) checkpoint with build/loader");
    } else if (heap_end > cur_brk && heap_end - cur_brk > MAX_BRK_MOVE) {
        LOG("WARNING: target heap far above the loader break, program break left as is: "
            "restore this (PIE) checkpoint with build/loader_pie");
    } else if (heap_end < cur_brk) {
        if ((o = find_overlap(descs, hdr.num_regions, heap_end, cur_brk)) >= 0) {
            log_str("[loader] WARNING: cannot move the program break to the target heap end, "
                    "a region lies in between: ");
            log_str(descs[o].name);
            log_str("\n");
        } else {
            fix_brk = heap_end;
        }
    } else if (heap_end > cur_brk) {
        if ((uint64_t)(uintptr_t)ckpt_data < heap_end)
            LOG("WARNING: checkpoint mapped below the target heap, program break left as is");
        else
            brk_grow = heap_end;
    }

    /* ---- 3. Restore FDs ---- */
    for (uint32_t i = 0; i < hdr.num_fds; i++) {
        log_str("[loader]   FD ");
        log_hex64((uint64_t)fds[i].fd);
        log_str("  flags: ");
        log_hex64((uint64_t)fds[i].flags);
        log_str("  offset: ");
        log_hex64((uint64_t)fds[i].offset);
        log_str("  path: ");
        log_str(fds[i].path);
        log_str("\n");
    }
    restore_fds(fds, hdr.num_fds, remaps, nremaps);

    /* ---- 4. Allocate scratch page ---- */
    void *scratch = mmap(SCRATCH_VA, SCRATCH_SZ,
                         PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                         -1, 0);
    if (scratch == MAP_FAILED) { perror("loader: scratch mmap"); return 1; }
    my_memset(scratch, 0, SCRATCH_SZ);

    /* ---- 5. Build restore_ctx + trampoline in the scratch page ---- */
    restore_ctx_t *ctx = (restore_ctx_t *)((char *)scratch);

    ctx->num_regions = hdr.num_regions;
    ctx->ckpt_data   = ckpt_data;
    ctx->descs       = descs;
    ctx->fs_base     = hdr.regs.fs_base;
    ctx->regs        = hdr.regs;
    ctx->brk_grow    = brk_grow;
    ctx->heap_start  = heap_start;
    ctx->heap_end    = heap_end;
    ctx->native      = (uint32_t)native;

    if (barrier) {
        const char *colon = strrchr(barrier, ':');
        if (!colon || (size_t)(colon - barrier) >= sizeof(ctx->barrier_path))
            DIE("--barrier expects FILE:N");
        memcpy(ctx->barrier_path, barrier, (size_t)(colon - barrier));
        ctx->barrier_n = (uint32_t)strtoul(colon + 1, NULL, 10);
    }

    size_t tramp_sz = (size_t)(rmc_tramp_end - rmc_tramp_start);
    ctx->tramp = (char *)scratch + SCRATCH_TRAMP_OFF;
    memcpy(ctx->tramp, rmc_tramp_start, tramp_sz);
    uint64_t v;
    v = fix_brk;
    memcpy(ctx->tramp + (rmc_tramp_brk - rmc_tramp_start), &v, 8);
    v = native ? 0 : 1;
    memcpy(ctx->tramp + (rmc_tramp_m5 - rmc_tramp_start), &v, 8);
    v = hdr.roi_entry_rip;
    memcpy(ctx->tramp + (rmc_tramp_rip - rmc_tramp_start), &v, 8);
    v = (uint64_t)(uintptr_t)ckpt_data;
    memcpy(ctx->tramp + (rmc_tramp_ckpt - rmc_tramp_start), &v, 8);
    v = map_len;
    memcpy(ctx->tramp + (rmc_tramp_ckpt_len - rmc_tramp_start), &v, 8);

    if (native) LOG("--native: m5_exit will be skipped");

    /* Scratch stack top = end of scratch page */
    void *scratch_top = (char *)scratch + SCRATCH_STACK_OFF;

    /* ---- 6. Switch to scratch stack and do restore ---- */
    LOG("Switching to scratch stack -> restoring -> jumping to ROI");
    switch_stack_and_restore(ctx, scratch_top);

    /* unreachable */
    return 1;
}
