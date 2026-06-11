/**
 * libckpt.c - Generic LD_PRELOAD checkpoint library for gem5 SE mode
 *
 * Trigger modes (first one to fire wins):
 *
 *   1. SIGUSR1 (always active):
 *        CKPT_OUTPUT=dump.ckpt LD_PRELOAD=./build/libckpt.so ./your_app &
 *        kill -SIGUSR1 $!
 *
 *   2. Timer (CKPT_AFTER_NS nanoseconds after process start):
 *        CKPT_OUTPUT=dump.ckpt CKPT_AFTER_NS=5000000000 \
 *          LD_PRELOAD=./build/libckpt.so ./your_app
 *
 *   3. Symbol hook (CKPT_AT_SYMBOL): fires at the Nth call to any
 *      dynamically-linked symbol.  Uses INT3 breakpoint patching;
 *      the original bytes are restored so the function runs normally
 *      after the dump.
 *        CKPT_OUTPUT=dump.ckpt CKPT_AT_SYMBOL=my_roi_func \
 *          CKPT_AT_SYMBOL_CALL=1 \
 *          LD_PRELOAD=./build/libckpt.so ./your_app
 *      CKPT_AT_SYMBOL_CALL defaults to 1 (first call).
 *
 * Compilation (handled by Makefile):
 *   gcc -O2 -shared -fPIC -o build/libckpt.so src/libckpt.c \
 *       build/dumper_pic.o -Isrc -ldl -lpthread
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
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <stdatomic.h>
#include <ucontext.h>

#include "checkpoint.h"

/* ------------------------------------------------------------------ */
/*  Forward declarations from dumper.c                                  */
/* ------------------------------------------------------------------ */
int ckpt_dump_impl(const char *path, ckpt_regs_t *regs);

/* ------------------------------------------------------------------ */
/*  Global state                                                        */
/* ------------------------------------------------------------------ */
static atomic_int  g_dumped      = 0;   /* 1 once a dump has been taken */
static const char *g_output_path = NULL;
static uint64_t    g_after_ns    = 0;   /* 0 = disabled */

/* --- Symbol-hook state -------------------------------------------- */
static char    g_sym_name[256]  = {0};  /* CKPT_AT_SYMBOL value       */
static void   *g_sym_addr       = NULL; /* resolved address            */
static uint8_t g_sym_orig[1]    = {0};  /* saved first byte (for INT3) */
static atomic_int g_sym_call_count = 0; /* how many times hook fired   */
static int     g_sym_target_call = 1;   /* CKPT_AT_SYMBOL_CALL value   */

/* ------------------------------------------------------------------ */
/*  Helpers: make a page (un)writable                                   */
/* ------------------------------------------------------------------ */
static void page_set_writable(void *addr, int writable)
{
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(getpagesize() - 1);
    int prot = PROT_READ | PROT_EXEC | (writable ? PROT_WRITE : 0);
    if (mprotect((void *)page, getpagesize(), prot) != 0)
        perror("[libckpt] mprotect");
}

/* ------------------------------------------------------------------ */
/*  Core: fill ckpt_regs_t from kernel ucontext and dump               */
/* ------------------------------------------------------------------ */
static void do_dump_from_ucontext(ucontext_t *uc)
{
    if (atomic_exchange(&g_dumped, 1) != 0) return; /* already dumped */

    ckpt_regs_t regs = {0};

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
    regs.cs     = (uint64_t) uc->uc_mcontext.gregs[REG_CSGSFS]        & 0xFFFF;
    regs.gs     = (uint64_t)(uc->uc_mcontext.gregs[REG_CSGSFS] >> 16) & 0xFFFF;
    regs.fs     = (uint64_t)(uc->uc_mcontext.gregs[REG_CSGSFS] >> 32) & 0xFFFF;

    syscall(158 /*arch_prctl*/, 0x1003 /*ARCH_GET_FS*/, &regs.fs_base);
    syscall(158 /*arch_prctl*/, 0x1004 /*ARCH_GET_GS*/, &regs.gs_base);
#else
#  error "libckpt only supports x86-64"
#endif

    fprintf(stderr, "[libckpt] Dumping checkpoint to: %s\n", g_output_path);
    fprintf(stderr, "[libckpt] RIP=0x%lx  RSP=0x%lx\n", regs.rip, regs.rsp);

    int rc = ckpt_dump_impl(g_output_path, &regs);
    if (rc != 0) {
        fprintf(stderr, "[libckpt] ERROR: ckpt_dump_impl returned %d\n", rc);
        _exit(1);
    } else {
        fprintf(stderr, "[libckpt] Done! Exiting application.\n");
        _exit(0);
    }
}

/* ------------------------------------------------------------------ */
/*  SIGUSR1 handler                                                     */
/* ------------------------------------------------------------------ */
static void sigusr1_handler(int sig, siginfo_t *info, void *ctx)
{
    (void)sig; (void)info;
    do_dump_from_ucontext((ucontext_t *)ctx);
}

/* ------------------------------------------------------------------ */
/*  SIGTRAP handler — fired by INT3 at the hooked symbol               */
/*                                                                      */
/*  INT3 is a 1-byte instruction (0xCC).  When it executes, the CPU    */
/*  pushes RIP pointing to the NEXT byte, so we subtract 1 to get the  */
/*  true start of the hooked function.                                  */
/*                                                                      */
/*  On each call:                                                       */
/*    - increment call counter                                           */
/*    - if counter < target: re-arm INT3 and continue                   */
/*    - if counter == target: dump checkpoint, restore original byte,   */
/*      and continue (function runs normally after the handler returns) */
/* ------------------------------------------------------------------ */
static void sigtrap_handler(int sig, siginfo_t *info, void *ctx)
{
    (void)sig; (void)info;
    ucontext_t *uc = (ucontext_t *)ctx;

    /* RIP after INT3 points one byte past the breakpoint */
    uintptr_t bp_addr = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP] - 1;

    if ((void *)bp_addr != g_sym_addr) {
        /* Not our breakpoint — let default handler take it */
        fprintf(stderr, "[libckpt] SIGTRAP at unexpected addr 0x%lx, aborting\n",
                (unsigned long)bp_addr);
        struct sigaction dfl = { .sa_handler = SIG_DFL };
        sigaction(SIGTRAP, &dfl, NULL);
        raise(SIGTRAP);
        return;
    }

    int call_no = atomic_fetch_add(&g_sym_call_count, 1) + 1;
    fprintf(stderr, "[libckpt] Symbol '%s' call #%d (target=%d)\n",
            g_sym_name, call_no, g_sym_target_call);

    /* Always restore the original byte first so the function can run */
    page_set_writable(g_sym_addr, 1);
    *(uint8_t *)g_sym_addr = g_sym_orig[0];
    page_set_writable(g_sym_addr, 0);

    /* Rewind RIP back to the start of the function */
    uc->uc_mcontext.gregs[REG_RIP] = (greg_t)bp_addr;

    if (call_no < g_sym_target_call) {
        /* Not yet the target call — re-arm breakpoint after single-step.
         * We use TF (Trap Flag, bit 8 of RFLAGS) to single-step over the
         * first instruction, then reinstall INT3 in the SIGTRAP that fires. */
        uc->uc_mcontext.gregs[REG_EFL] |= (1 << 8); /* set TF */
        /* g_sym_call_count already incremented; sigtrap will re-arm */
        return;
    }

    /* This IS the target call — dump checkpoint */
    do_dump_from_ucontext(uc);
    /* Return: kernel restores regs from ucontext, execution continues at
     * the original function (original byte already restored above). */
}

/* ------------------------------------------------------------------ */
/*  Single-step SIGTRAP re-arm handler                                  */
/*  After TF fires we reinstall INT3 and clear TF.                      */
/* ------------------------------------------------------------------ */
static int g_rearm_pending = 0;

static void sigtrap_rearm_or_hook(int sig, siginfo_t *info, void *ctx)
{
    ucontext_t *uc = (ucontext_t *)ctx;

    if (g_rearm_pending) {
        /* We're here because of TF single-step — reinstall INT3 */
        g_rearm_pending = 0;
        uc->uc_mcontext.gregs[REG_EFL] &= ~(greg_t)(1 << 8); /* clear TF */
        page_set_writable(g_sym_addr, 1);
        *(uint8_t *)g_sym_addr = 0xCC;
        page_set_writable(g_sym_addr, 0);
        return;
    }

    /* Normal breakpoint hit */
    sigtrap_handler(sig, info, ctx);

    /* If TF was set by sigtrap_handler (not-yet-target call), mark rearm */
    if (uc->uc_mcontext.gregs[REG_EFL] & (1 << 8))
        g_rearm_pending = 1;
}

/* ------------------------------------------------------------------ */
/*  Symbol resolution: dlsym first, then in-process ELF symtab parser  */
/* ------------------------------------------------------------------ */
#include <link.h>
#include <elf.h>
#include <sys/stat.h>

/*
 * elf_find_symbol: mmap the ELF file and walk its .symtab section
 * to find the symbol's value (VA offset for PIE, absolute for non-PIE).
 * Returns the symbol's runtime address, or NULL if not found.
 */
static void *elf_find_symbol(const char *exe_path, const char *name)
{
    int fd = open(exe_path, O_RDONLY);
    if (fd < 0) return NULL;

    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return NULL; }

    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return NULL;

    void *result = NULL;

    Elf64_Ehdr *ehdr = (Elf64_Ehdr *)map;
    if (memcmp(ehdr->e_ident, ELFMAG, SELFMAG) != 0) goto done;

    Elf64_Shdr *shdrs  = (Elf64_Shdr *)((char *)map + ehdr->e_shoff);
    Elf64_Shdr *shstrtab_hdr = &shdrs[ehdr->e_shstrndx];
    const char *shstrtab = (const char *)map + shstrtab_hdr->sh_offset;

    Elf64_Shdr *symtab_hdr  = NULL;
    Elf64_Shdr *strtab_hdr  = NULL;

    for (int i = 0; i < ehdr->e_shnum; i++) {
        const char *sname = shstrtab + shdrs[i].sh_name;
        if (shdrs[i].sh_type == SHT_SYMTAB && strcmp(sname, ".symtab") == 0)
            symtab_hdr = &shdrs[i];
        if (shdrs[i].sh_type == SHT_STRTAB && strcmp(sname, ".strtab") == 0)
            strtab_hdr = &shdrs[i];
    }

    if (!symtab_hdr || !strtab_hdr) goto done;

    Elf64_Sym  *syms    = (Elf64_Sym  *)((char *)map + symtab_hdr->sh_offset);
    const char *strtab  = (const char *)((char *)map + strtab_hdr->sh_offset);
    size_t      nsyms   = symtab_hdr->sh_size / sizeof(Elf64_Sym);

    /* Get load base and compute slide from ELF LOAD segment p_vaddr */
    uintptr_t load_base = 0;
    {
        FILE *fm = fopen("/proc/self/maps", "r");
        if (fm) {
            char line[512];
            while (fgets(line, sizeof(line), fm)) {
                if (strstr(line, exe_path) && strstr(line, "r-xp")) {
                    sscanf(line, "%lx", &load_base);
                    break;
                }
            }
            fclose(fm);
        }
    }

    /* Find the executable PT_LOAD segment's p_vaddr to compute the slide.
     * We look for PF_X (execute bit) — that's the text segment.
     * slide = load_base - p_vaddr
     * runtime_addr = sym.st_value + slide
     */
    uintptr_t slide = 0;
    if (load_base > 0) {
        Elf64_Phdr *phdrs = (Elf64_Phdr *)((char *)map + ehdr->e_phoff);
        uintptr_t text_vaddr = 0;
        int found = 0;
        for (int i = 0; i < ehdr->e_phnum; i++) {
            if (phdrs[i].p_type == PT_LOAD && (phdrs[i].p_flags & 0x1 /*PF_X*/)) {
                text_vaddr = (uintptr_t)phdrs[i].p_vaddr;
                found = 1;
                break;
            }
        }
        if (!found) {
            /* Fallback: use first PT_LOAD */
            for (int i = 0; i < ehdr->e_phnum; i++) {
                if (phdrs[i].p_type == PT_LOAD) {
                    text_vaddr = (uintptr_t)phdrs[i].p_vaddr;
                    break;
                }
            }
        }
        /* For the text segment in a PIE binary the slide is:
         * actual_text_base - text_vaddr
         * But load_base is the actual_text_base from /proc/self/maps r-xp line. */
        slide = load_base - text_vaddr;
    }

    for (size_t i = 0; i < nsyms; i++) {
        if (syms[i].st_value == 0) continue;
        if (ELF64_ST_TYPE(syms[i].st_info) != STT_FUNC &&
            ELF64_ST_TYPE(syms[i].st_info) != STT_NOTYPE) continue;
        const char *sname = strtab + syms[i].st_name;
        if (strcmp(sname, name) == 0) {
            uintptr_t val  = (uintptr_t)syms[i].st_value;
            uintptr_t addr = val + slide;
            fprintf(stderr,
                    "[libckpt] Found '%s' via ELF symtab: val=0x%lx slide=0x%lx -> %p\n",
                    name, val, slide, (void *)addr);
            result = (void *)addr;
            break;
        }
    }

done:
    munmap(map, (size_t)st.st_size);
    return result;
}

static void *resolve_symbol(const char *name)
{
    /* Try 1: normal dlsym across all loaded objects */
    void *addr = dlsym(RTLD_DEFAULT, name);
    if (addr) return addr;

    /* Try 2: explicitly open the main executable's dynsym */
    char exe_path[512] = {0};
    ssize_t n = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (n > 0) {
        void *h = dlopen(exe_path, RTLD_NOW | RTLD_NOLOAD);
        if (!h) h = dlopen(exe_path, RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            addr = dlsym(h, name);
            if (addr) return addr;
        }

        /* Try 3: parse .symtab directly (catches non-exported/static symbols)
         * NOTE: we do this in-process with mmap — no fork, no popen. */
        addr = elf_find_symbol(exe_path, name);
        if (addr) return addr;
    }

    return NULL;
}

/* ------------------------------------------------------------------ */
/*  Install INT3 breakpoint at the resolved symbol address              */
/* ------------------------------------------------------------------ */
static void install_symbol_hook(void)
{
    g_sym_addr = resolve_symbol(g_sym_name);
    if (!g_sym_addr) {
        fprintf(stderr, "[libckpt] WARNING: symbol '%s' not found\n", g_sym_name);
        return;
    }

    fprintf(stderr, "[libckpt] Hooking '%s' @ %p (will fire on call #%d)\n",
            g_sym_name, g_sym_addr, g_sym_target_call);

    /* Save original first byte */
    g_sym_orig[0] = *(uint8_t *)g_sym_addr;

    /* Install SIGTRAP handler */
    struct sigaction sa = {0};
    sa.sa_flags     = SA_SIGINFO | SA_RESTART;
    sa.sa_sigaction = sigtrap_rearm_or_hook;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTRAP, &sa, NULL);

    /* Write INT3 */
    page_set_writable(g_sym_addr, 1);
    *(uint8_t *)g_sym_addr = 0xCC;
    page_set_writable(g_sym_addr, 0);

    fprintf(stderr, "[libckpt] INT3 installed at %p (orig byte=0x%02x)\n",
            g_sym_addr, g_sym_orig[0]);
}

/* ------------------------------------------------------------------ */
/*  Timer thread: raise SIGUSR1 after CKPT_AFTER_NS nanoseconds        */
/* ------------------------------------------------------------------ */
static void *timer_thread(void *arg)
{
    (void)arg;
    struct timespec ts = {
        .tv_sec  = (time_t)(g_after_ns / 1000000000ULL),
        .tv_nsec = (long)  (g_after_ns % 1000000000ULL),
    };
    nanosleep(&ts, NULL);

    if (!atomic_load(&g_dumped))
        raise(SIGUSR1);
    return NULL;
}

/* ------------------------------------------------------------------ */
/*  Constructor: runs when the .so is loaded by the dynamic linker     */
/* ------------------------------------------------------------------ */
__attribute__((constructor))
static void libckpt_init(void)
{
    /* CRITICAL: remove ourselves from the environment immediately so that
     * no child process (shells, nm, make, etc.) inherits LD_PRELOAD and
     * causes a fork bomb by re-loading libckpt.so recursively. */
    unsetenv("LD_PRELOAD");

    g_output_path = getenv("CKPT_OUTPUT");
    if (!g_output_path) g_output_path = "libckpt_dump.ckpt";

    const char *after_str = getenv("CKPT_AFTER_NS");
    if (after_str) g_after_ns = (uint64_t)strtoull(after_str, NULL, 10);


    const char *sym_str = getenv("CKPT_AT_SYMBOL");
    if (sym_str) {
        strncpy(g_sym_name, sym_str, sizeof(g_sym_name) - 1);
        const char *call_str = getenv("CKPT_AT_SYMBOL_CALL");
        g_sym_target_call = call_str ? (int)strtol(call_str, NULL, 10) : 1;
        if (g_sym_target_call < 1) g_sym_target_call = 1;
    }

    /* Install SIGUSR1 handler (always available) */
    struct sigaction sa = {0};
    sa.sa_flags     = SA_SIGINFO | SA_RESTART;
    sa.sa_sigaction = sigusr1_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGUSR1, &sa, NULL);

    fprintf(stderr, "[libckpt] Initialized. Output=%s  AfterNs=%lu  Symbol=%s(call#%d)\n",
            g_output_path, (unsigned long)g_after_ns,
            g_sym_name[0] ? g_sym_name : "(none)", g_sym_target_call);
    fprintf(stderr, "[libckpt] PID=%d  send SIGUSR1 to trigger manually.\n",
            (int)getpid());

    /* Install symbol hook if requested */
    if (g_sym_name[0])
        install_symbol_hook();

    /* Launch timer thread if requested */
    if (g_after_ns > 0) {
        pthread_t tid;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&tid, &attr, timer_thread, NULL);
        pthread_attr_destroy(&attr);
        fprintf(stderr, "[libckpt] Timer thread started (%lu ns).\n",
                (unsigned long)g_after_ns);
    }
}
