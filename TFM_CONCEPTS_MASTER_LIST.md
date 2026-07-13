# Master's Thesis (TFM): Checkpointing Architecture & Concepts Guide

This document serves as the master list of all theoretical and practical concepts utilized across the entire `real_machine_checkpoint` codebase (`libckpt.c`, `dumper.c`, `loader.c`, and `dumper_asm.S`). 

To precisely explain your architecture in your TFM, you must master the following concepts:

---

## 1. Operating System Virtual Memory & `procfs`
*Used extensively in `dumper.c` to capture memory state and `loader.c` to restore it.*
* **Virtual Memory Areas (VMAs):** How the OS maps physical memory into a process's virtual address space.
* **`/proc/self/maps`:** The procfs interface used to read a process's memory layout at runtime.
* **Memory Protection:** The Read, Write, and Execute (`PROT_READ`, `PROT_WRITE`, `PROT_EXEC`) flags and how they map to hardware page tables.
* **Memory Management Syscalls:** Detailed understanding of `mmap` (for allocating specific addresses with `MAP_FIXED`), `munmap` (for clearing regions), and `mprotect` (for dynamically altering page permissions).

## 2. POSIX Signals & Context Extraction
*Used in `libckpt.c` for catching execution at exact moments.*
* **Advanced Signal Handling (`sigaction`):** Using the `SA_SIGINFO` flag to intercept signals (`SIGTRAP`, `SIGUSR1`) instead of the basic `signal()` function.
* **Execution Context (`ucontext_t` / `mcontext_t`):** How the Linux kernel dumps the CPU's hardware register state onto the user stack before invoking a signal handler, and how modifying this struct changes where the program resumes.
* **Signal Return (`rt_sigreturn`):** The system call used behind the scenes to restore the hardware state from `ucontext_t` when a signal handler finishes.

## 3. Dynamic Code Patching & Breakpoints
*Used in `libckpt.c` for the `CKPT_AT_SYMBOL` feature.*
* **Software Breakpoints (`INT3` / `0xCC`):** The 1-byte x86 instruction used by debuggers to force a hardware trap (Exception #3).
* **Instruction Pointer (`RIP`) Offset:** Understanding why the CPU leaves `RIP` pointing exactly 1 byte *after* the `0xCC` instruction, necessitating `bp_addr = REG_RIP - 1`.
* **Self-Modifying Code:** The practice of using `getpagesize()` and bitwise alignment to strip `PROT_EXEC` protections, rewrite the machine code byte, and restore execution.

## 4. Hardware Single-Stepping
*Used in `libckpt.c` to re-arm breakpoints after execution.*
* **The `EFLAGS` / `RFLAGS` Register:** The CPU register holding boolean state flags.
* **The Trap Flag (`TF` - Bit 8):** Forcing the CPU to execute exactly one machine instruction and then immediately fire a `SIGTRAP` (Exception #1). This is required to step over the original instruction before putting the `0xCC` breakpoint back.

## 5. Thread-Local Storage (TLS) & Segment Registers
*Used in `libckpt.c` and `loader.c` because standard restoration breaks `libc`.*
* **The `FS` and `GS` Registers:** Legacy x86 segment registers repurposed in 64-bit mode as base pointers for Thread-Local variables (like `errno`).
* **The `arch_prctl` System Call:** Because `fs_base` lives in protected CPU Model-Specific Registers (MSRs), you must explain the use of `ARCH_GET_FS` and `ARCH_SET_FS` to backup and restore `libc`'s thread data.

## 6. Bare-Metal Assembly & ABI (Application Binary Interface)
*Used in `dumper_asm.S` and the inline assembly of `loader.c`.*
* **The System V AMD64 ABI:** The rules governing which registers hold function arguments (`RDI`, `RSI`, `RDX`, `RCX`, `R8`, `R9`) and which must be preserved across calls.
* **Naked Functions (`__attribute__((naked))`):** Instructing the C compiler *not* to generate function prologues or epilogues, giving you 100% control over the stack pointer.
* **Raw Syscalls in Assembly:** Bypassing `libc` wrappers to prevent memory allocation or stack corruption during the delicate restore phase.

## 7. Userspace Checkpoint/Restore (C/R) Mechanics
*The core architecture of the `loader.c`.*
* **Avoiding `execve` boundaries:** Why traditional process loading wipes memory, and how your custom loader maps the checkpoint directly into its own address space.
* **Loader Relocation (`-Wl,-Ttext-segment=0x20000000`):** Linking the loader binary at an artificially high memory address (512 MB) so it doesn't collide with the standard `0x400000` load address of the target application being restored.
* **Stack Pivoting:** The technique of dynamically allocating a "scratch stack" (`0x7F00...`) and manually moving the `RSP` register to it, so the loader doesn't accidentally overwrite its own stack while restoring the target's stack.

## 8. Compiler Toolchains & `libc` Internals
*The core reason we switched to the Docker pipeline.*
* **Dynamic Linking vs Static Linking:** The difference between resolving symbols at runtime (`ld.so`) versus baking them into the binary.
* **IFUNC (Indirect Functions) & CPUID Dispatch:** How `glibc` dynamically queries the CPU at startup and silently swaps functions like `memcpy` for highly optimized AVX/FMA variants.
* **The `musl` Libc Philosophy:** Why using Alpine Linux and `musl-gcc` solves the gem5 panics by providing a strictly compliant, predictable, and IFUNC-free standard library.

## 9. Atomics and Thread Safety
*Used in `libckpt.c` to prevent multi-threading race conditions.*
* **Hardware Atomics (`stdatomic.h`):** Translating operations like `atomic_fetch_add` to `LOCK XADD` instructions to ensure atomic counting of function calls (`g_sym_call_count`) and dump flags (`g_dumped`) across parallel threads.
