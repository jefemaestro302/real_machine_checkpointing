/**
 * loader.c - Custom static loader for checkpoint restore (v4)
 *
 * Key architectural insight:
 *   - Loader .text:  0x20000000+ (via -Wl,-Ttext-segment=0x20000000)
 *   - Target app:    0x400000 - 0x1505000 (from dump)
 *   - Stack (target): 0x7ffffffdd000 - 0x7ffffffff000
 *
 * The loader's .text is NEVER clobbered by the restore.
 * The loader's STACK (originally low, from execv) IS clobbered when we
 * restore the target's stack region.
 *
 * Solution: switch to a scratch stack at 0x7F0000000000 BEFORE the
 * restore loop, then do all restores on the scratch stack, then call
 * setcontext() to jump to ROI.
 *
 * Flow:
 *  main():
 *    1. Read dump header + descriptors
 *    2. Load all region payloads into heap buffers
 *    3. Allocate scratch page (0x7F0000000000, PROT_RW)
 *    4. Build ucontext_t in scratch page
 *    5. switch_to_scratch_and_restore(bufs, descs, uc, num_regions,
 *                                     scratch_stack_top)
 *       ↓ (now on scratch stack)
 *    6. restore_all_regions()  [mmap + memcpy + mprotect for each]
 *    7. arch_prctl ARCH_SET_FS
 *    8. setcontext(uc)  -> jumps to ROI
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
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <ucontext.h>
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

void my_memcpy(void *dest, const void *src, size_t n) {
    unsigned char *d = dest;
    const unsigned char *s = src;
    while (n--) {
        *d++ = *s++;
    }
}

static inline void log_str(const char *s)
{
    size_t n = 0;
    while (s[n]) n++;
    (void)write(STDERR_FILENO, s, n);
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
    (void)write(STDERR_FILENO, "0x", 2);
    size_t len = (size_t)(&buf[18] - p);
    (void)write(STDERR_FILENO, p, len ? len : 1);
}

#define DIE(msg)  do { log_str("[loader] FATAL: " msg "\n"); _Exit(1); } while(0)
#define LOG(msg)  do { log_str("[loader] " msg "\n"); } while(0)

/* ------------------------------------------------------------------ */
/*  Exact-read helper                                                    */
/* ------------------------------------------------------------------ */
static ssize_t pread_all(int fd, void *buf, size_t n, off_t off)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = pread(fd, (char *)buf + done, n - done, off + done);
        if (r <= 0) return r == 0 ? (ssize_t)done : -1;
        done += (size_t)r;
    }
    return (ssize_t)done;
}

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
/*  Scratch page layout                                                  */
/*                                                                       */
/*  0x7F0000000000  +-----------------------------------------------+  */
/*                  | ucontext_t  (968 bytes)                       |  */
/*                  +-----------------------------------------------+  */
/*                  | restore_ctx (num_regions, bufs*, descs*, fs)  |  */
/*                  +-----------------------------------------------+  */
/*  + STACK_OFF     | Scratch stack (grows downward from top)       |  */
/*                  +-----------------------------------------------+  */
/* ------------------------------------------------------------------ */
#define SCRATCH_VA     ((void *)0x7E0000000000ULL)
#define SCRATCH_SZ     (131072)                  /* 128 KB, plenty   */
#define SCRATCH_STACK_OFF (SCRATCH_SZ)           /* top of scratch   */

/* Parameters for the restore stage, stored in the scratch page */
typedef struct {
    uint32_t       num_regions;
    uint32_t       _pad;
    int            ckpt_fd;
    ckpt_region_t *descs;         /* region descriptors                 */
    uint64_t       fs_base;       /* TLS fs_base to restore             */
    ucontext_t    *uc;            /* pointer to the ucontext in scratch */
    uint64_t       loader_vdso_start;
    uint64_t       loader_vdso_size;
    uint64_t       loader_vvar_start;
    uint64_t       loader_vvar_size;
    uint64_t       loader_vvar_vclock_start;
    uint64_t       loader_vvar_vclock_size;
    ckpt_regs_t    regs;
} restore_ctx_t;

/* ------------------------------------------------------------------ */
/*  Stub to restore TLS safely after setcontext                       */
/* ------------------------------------------------------------------ */
uint64_t stub_fs_base = 0;
uint64_t stub_roi_rip = 0;
uint64_t stub_scratch_rax = 0;
uint64_t stub_scratch_rdi = 0;
uint64_t stub_scratch_rsi = 0;
uint64_t stub_scratch_rcx = 0;
uint64_t stub_scratch_r11 = 0;

__attribute__((naked, used)) static void fs_restore_stub(void) {
    __asm__ volatile (
        "movq %rax, stub_scratch_rax(%rip)\n\t"
        "movq %rdi, stub_scratch_rdi(%rip)\n\t"
        "movq %rsi, stub_scratch_rsi(%rip)\n\t"
        "movq %rcx, stub_scratch_rcx(%rip)\n\t"
        "movq %r11, stub_scratch_r11(%rip)\n\t"
        
        "movq stub_fs_base(%rip), %rsi\n\t"
        "test %rsi, %rsi\n\t"
        "je 1f\n\t"
        
        "movl $158, %eax\n\t"
        "movl $0x1002, %edi\n\t"
        "syscall\n\t"
        
        "1:\n\t"
        "movq stub_scratch_rax(%rip), %rax\n\t"
        "movq stub_scratch_rdi(%rip), %rdi\n\t"
        "movq stub_scratch_rsi(%rip), %rsi\n\t"
        "movq stub_scratch_rcx(%rip), %rcx\n\t"
        "movq stub_scratch_r11(%rip), %r11\n\t"
        "jmp *stub_roi_rip(%rip)\n\t"
    );
}

/* ------------------------------------------------------------------ */
/*  Stage 2: restore all regions, then setcontext (on scratch stack)    */
/*                                                                       */
/*  This function NEVER uses the loader's original stack.               */
/*  It runs entirely on the scratch stack (switched in stage-switch).   */
/* ------------------------------------------------------------------ */
__attribute__((noinline, noreturn, used))
static void restore_and_jump(restore_ctx_t *ctx)
{
    log_str("[loader] restore_and_jump: restoring regions\n");
    int fd_maps = open("/proc/self/maps", O_RDONLY);
    if (fd_maps >= 0) {
        char buf_maps[1024];
        ssize_t n;
        while ((n = read(fd_maps, buf_maps, sizeof(buf_maps))) > 0) {
            write(1, buf_maps, n);
        }
        close(fd_maps);
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
        if (m == MAP_FAILED) {
            log_str("[loader] mmap failed in restore_and_jump! start=0x");
            log_hex64(d->start);
            log_str(" sz=0x");
            log_hex64(sz);
            log_str("\n");
            perror("mmap");
        } else {
            if (d->data_size > 0) {
                ssize_t ret = pread_all(ctx->ckpt_fd, m, (size_t)d->data_size, d->file_offset);
                if (ret != (ssize_t)d->data_size) {
                    log_str("ERROR: pread_all returned ");
                    log_hex64(ret);
                    log_str(" expected ");
                    log_hex64(d->data_size);
                    log_str("\n");
                }
            }
        }
        mprotect(m, sz, prot);
    }
    
    log_str("[loader] Setting FS base and jumping to ROI\n");
    if (stub_fs_base) {
        syscall(158, 0x1002, stub_fs_base);
    }

    ckpt_regs_t *r = &ctx->regs;
    __asm__ volatile (
        "movq 0x38(%%rax), %%rsp\n\t"
        "pushq 0x80(%%rax)\n\t"
        "pushq 0x88(%%rax)\n\t"
        "popfq\n\t"
        "movq 0x78(%%rax), %%r15\n\t"
        "movq 0x70(%%rax), %%r14\n\t"
        "movq 0x68(%%rax), %%r13\n\t"
        "movq 0x60(%%rax), %%r12\n\t"
        "movq 0x58(%%rax), %%r11\n\t"
        "movq 0x50(%%rax), %%r10\n\t"
        "movq 0x48(%%rax), %%r9\n\t"
        "movq 0x40(%%rax), %%r8\n\t"
        "movq 0x30(%%rax), %%rbp\n\t"
        "movq 0x28(%%rax), %%rdi\n\t"
        "movq 0x20(%%rax), %%rsi\n\t"
        "movq 0x18(%%rax), %%rdx\n\t"
        "movq 0x10(%%rax), %%rcx\n\t"
        "movq 0x08(%%rax), %%rbx\n\t"
        "movq 0x00(%%rax), %%rax\n\t"
        "ret\n\t"
        :
        : "a"(r)
    );
    while(1);
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

/* ================================================================== */
/*  Main                                                                 */
/* ================================================================== */
int main(int argc, char *argv[])
{
    if (argc < 2) { log_str("Usage: loader <dump.ckpt>\n"); return 1; }

    LOG("Opening checkpoint...");
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("loader: open"); return 1; }

    /* ---- 1. Read header ---- */
    ckpt_header_t hdr;
    if (read_exact(fd, &hdr, sizeof(hdr)) != sizeof(hdr)) DIE("Header read");
    if (hdr.magic != CKPT_MAGIC)     DIE("Bad magic");
    if (hdr.version != CKPT_VERSION) DIE("Version mismatch");

    log_str("[loader] ROI RIP=");
    log_hex64(hdr.roi_entry_rip);
    log_str("  RSP=");
    log_hex64(hdr.regs.rsp);
    log_str("\n");

    /* ---- 2. Read region descriptors ---- */
    size_t desc_sz = hdr.num_regions * sizeof(ckpt_region_t);
    ckpt_region_t *descs = malloc(desc_sz);
    if (!descs) DIE("OOM descs");
    if (read_exact(fd, descs, desc_sz) != (ssize_t)desc_sz) DIE("Descs read");    for (uint32_t i = 0; i < hdr.num_regions; i++) {
        ckpt_region_t *d = &descs[i];
        if (d->start == 0x7fffeffff000) {
            log_str("MAIN FOUND STACK: file_off=");
            log_hex64(d->file_offset);
            log_str("\n");
        }
        log_str("[loader]   REGION 0x");
        log_hex64(d->start);
        log_str("-0x");
        log_hex64(d->end);
        log_str("  ");
        log_str(d->name);
        log_str("\n");
    }
    /* fd is left open for restore_and_jump */

    /* ---- 4. Allocate scratch page ---- */
    void *scratch = mmap(SCRATCH_VA, SCRATCH_SZ,
                         PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
                         -1, 0);
    if (scratch == MAP_FAILED) { perror("loader: scratch mmap"); return 1; }
    my_memset(scratch, 0, SCRATCH_SZ);

    /* ---- 5. Build ucontext_t in scratch page ---- */
    ucontext_t *uc = (ucontext_t *)scratch;

    /* IMPORTANT: getcontext() fills in the FP/SSE/XSAVE state which
     * setcontext() requires on modern x86-64 (PKRU etc.).
     * We get a valid baseline, then override only the GPRs. */
    getcontext(uc);   /* fills uc_mcontext.fpregs, uc_sigmask, etc. */

    /* Clear uc_stack and uc_link: we're doing a raw register restore,
     * not makecontext/swapcontext. Leaving uc_stack filled with the
     * loader's stack pointer can cause setcontext to misbehave. */
    uc->uc_stack.ss_sp    = NULL;
    uc->uc_stack.ss_size  = 0;
    uc->uc_stack.ss_flags = SS_DISABLE;
    uc->uc_link           = NULL;


    uc->uc_mcontext.gregs[REG_R8]     = (greg_t)hdr.regs.r8;
    uc->uc_mcontext.gregs[REG_R9]     = (greg_t)hdr.regs.r9;
    uc->uc_mcontext.gregs[REG_R10]    = (greg_t)hdr.regs.r10;
    uc->uc_mcontext.gregs[REG_R11]    = (greg_t)hdr.regs.r11;
    uc->uc_mcontext.gregs[REG_R12]    = (greg_t)hdr.regs.r12;
    uc->uc_mcontext.gregs[REG_R13]    = (greg_t)hdr.regs.r13;
    uc->uc_mcontext.gregs[REG_R14]    = (greg_t)hdr.regs.r14;
    uc->uc_mcontext.gregs[REG_R15]    = (greg_t)hdr.regs.r15;
    uc->uc_mcontext.gregs[REG_RDI]    = (greg_t)hdr.regs.rdi;
    uc->uc_mcontext.gregs[REG_RSI]    = (greg_t)hdr.regs.rsi;
    uc->uc_mcontext.gregs[REG_RBP]    = (greg_t)hdr.regs.rbp;
    uc->uc_mcontext.gregs[REG_RBX]    = (greg_t)hdr.regs.rbx;
    uc->uc_mcontext.gregs[REG_RDX]    = (greg_t)hdr.regs.rdx;
    uc->uc_mcontext.gregs[REG_RAX]    = (greg_t)hdr.regs.rax;
    uc->uc_mcontext.gregs[REG_RCX]    = (greg_t)hdr.regs.rcx;
    uc->uc_mcontext.gregs[REG_RSP]    = (greg_t)hdr.regs.rsp;
    
    /* Instead of jumping to the ROI directly, jump to our stub that will
     * fix up fs_base and then jump to the ROI. */
    stub_fs_base = hdr.regs.fs_base;
    stub_roi_rip = hdr.roi_entry_rip;
    uc->uc_mcontext.gregs[REG_RIP]    = (greg_t)fs_restore_stub;

    uc->uc_mcontext.gregs[REG_EFL]    = (greg_t)hdr.regs.rflags;
    uc->uc_mcontext.gregs[REG_CSGSFS] = (greg_t)(
        (hdr.regs.cs & 0xffffULL) |
        ((hdr.regs.gs & 0xffffULL) << 16) |
        ((hdr.regs.fs & 0xffffULL) << 48)
    );
    /* NOTE: fpregs is already set by getcontext() - do NOT set to NULL */
    /* uc->uc_mcontext.fpregs is valid from getcontext() */

    /* The fpregs buffer getcontext() filled is on the loader's stack.
     * Since the loader's stack may be clobbered, we need to copy the
     * fpregs into the scratch page too. */
    if (uc->uc_mcontext.fpregs) {
        /* Copy the fpstate (576 bytes for FXSAVE, more for XSAVE) to
         * the scratch page after the ucontext_t.
         * We reserve 4096 bytes for it to be safe with XSAVE. */
        void *fp_dst = (char *)scratch + sizeof(ucontext_t);
        my_memcpy(fp_dst, uc->uc_mcontext.fpregs, 4096 < (SCRATCH_SZ - sizeof(ucontext_t)) ? 4096 : (SCRATCH_SZ - sizeof(ucontext_t)));
        uc->uc_mcontext.fpregs = fp_dst;
    }

    /* ---- 6. Build restore_ctx in scratch page ----
     * Layout: [ucontext_t][fpstate 4096B][restore_ctx_t][scratch stack] */
    restore_ctx_t *ctx = (restore_ctx_t *)((char *)scratch + sizeof(ucontext_t) + 4096);

    ctx->num_regions = hdr.num_regions;
    ctx->ckpt_fd     = fd;
    ctx->descs       = descs;
    ctx->fs_base     = hdr.regs.fs_base;
    ctx->uc          = uc;
    ctx->regs        = hdr.regs;

    FILE *fm = fopen("/proc/self/maps", "r");
    char line[512];
    ctx->loader_vdso_start = 0; ctx->loader_vdso_size = 0;
    ctx->loader_vvar_start = 0; ctx->loader_vvar_size = 0;
    ctx->loader_vvar_vclock_start = 0; ctx->loader_vvar_vclock_size = 0;
    if (fm) {
        while (fgets(line, sizeof(line), fm)) {
            uint64_t s, e;
            if (sscanf(line, "%lx-%lx", &s, &e) == 2) {
                if (strstr(line, "[vdso]")) { 
                    ctx->loader_vdso_start = s; ctx->loader_vdso_size = e - s; 
                } else if (strstr(line, "[vvar_vclock]")) { 
                    ctx->loader_vvar_vclock_start = s; ctx->loader_vvar_vclock_size = e - s; 
                } else if (strstr(line, "[vvar]")) { 
                    ctx->loader_vvar_start = s; ctx->loader_vvar_size = e - s; 
                }
            }
        }
        fclose(fm);
    }

    /* Scratch stack top = end of scratch page */
    void *scratch_top = (char *)scratch + SCRATCH_STACK_OFF;

    /* ---- 7. Switch to scratch stack and do restore ---- */
    LOG("Switching to scratch stack -> restoring -> setcontext");
    switch_stack_and_restore(ctx, scratch_top);

    /* unreachable */
    return 1;
}
