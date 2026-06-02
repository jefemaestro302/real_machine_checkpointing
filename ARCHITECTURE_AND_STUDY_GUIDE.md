# Real Machine Checkpointing: Architecture & Study Guide

This document is designed to serve as a comprehensive study guide. It breaks down the entire project we built, the problems we solved, the architectural decisions we made, and provides a syllabus of low-level Linux/x86_64 concepts you should study to deeply understand the mechanics.

---

## 1. The Core Problem
Simulating massive, complex applications (like Tailbench's Silo or img-dnn) directly in **gem5 Syscall Emulation (SE) mode** is notoriously difficult and slow. Gem5 SE mode lacks a real operating system, meaning it struggles with:
- Multi-threading setup and complex `clone()` syscalls.
- Heavy OS-level initialization.
- Modern `glibc` dynamic loading (resolving symbols, mapping hundreds of libraries).

**Our Solution:** 
Let the real machine (or a fast emulator like Intel SDE) handle all the heavy lifting: process initialization, parsing configs, loading libraries, and warming up the caches. Exactly when the application enters the **Region of Interest (ROI)**, we freeze the process, dump its entire memory and CPU state to a file, and then inject that pure, raw state directly into gem5. gem5 skips the initialization and jumps straight to simulating the instructions that matter.

---

## 2. Component Breakdown

### A. The Interceptor (`libckpt.so`)
We inject a shared library into the target application using the `LD_PRELOAD` environment variable. This forces the OS to load our code before the application's own code.
- **Why `LD_PRELOAD`?** It allows us to intercept the process without modifying the application's source code or its Makefiles. It works completely transparently.
- **Triggers:** We needed a way to tell the application *when* to freeze and dump its state. We implemented three mechanisms:
  1. **Manual:** Waiting for a Linux signal (`SIGUSR1`).
  2. **Time-based:** Waiting for a certain amount of nanoseconds (`CKPT_AFTER_NS`).
  3. **Symbol-based (The hardest!):** Waiting until a specific function (e.g., `target_function`) is called.

### B. The Dumper (`dumper.c` / `dumper_asm.S`)
Once a trigger fires, we must save the state of the world to `tailbench_dump.ckpt`.
1. **CPU State:** We capture all general-purpose registers (RAX, RBX, RSP, RIP, etc.) using `getcontext()` or pure assembly (`dumper_asm.S`) to avoid corrupting the stack or the instruction pointer. We also capture `fs_base` via `arch_prctl`.
2. **Memory Maps:** We parse `/proc/self/maps` to find every single block of memory currently allocated to the process (the heap, the stack, the executable code, loaded libraries). We iterate through these and use `pread` to copy their raw bytes directly into the file.

### C. The Restorer (`loader.c`)
This is the program we actually execute inside gem5. It is statically compiled (`-static`) so that it doesn't rely on dynamically loading libraries (which would pollute the memory space we are trying to restore).
1. **Memory Injection:** The loader reads the `.ckpt` file. For every memory region, it uses the `mmap` syscall with the `MAP_FIXED` flag to forcefully overwrite its own memory space with the memory space of the dumped application. 
2. **Context Switch:** It switches to a safe "scratch stack", forcefully restores the `fs_base` register via `syscall(158)` (which is `arch_prctl`), loads all the dumped registers into the CPU using inline assembly, and executes a `jmp` instruction directly to the target application's saved Instruction Pointer (RIP).

---

## 3. The "Hacks" & Engineering Breakthroughs

During development, we encountered several massive roadblocks and solved them with clever low-level engineering:

### 1. The PIE/ASLR Slide & In-Process ELF Parsing
**The Problem:** Modern Linux compiles binaries as Position Independent Executables (PIE). This means every time the program runs, Address Space Layout Randomization (ASLR) shifts the memory addresses by a random offset (the "slide"). When we wanted to hook `target_function`, we couldn't just guess its memory address. Furthermore, standard functions like `dlsym()` only work for *exported* shared library symbols (`.dynsym`), not internal application functions.
**The Solution:** We wrote our own in-process ELF parser in `libckpt.c`. When the library loads:
1. It opens its own executable file from disk (`/proc/self/exe`).
2. It parses the ELF headers to locate the `.symtab` (Symbol Table) and `.strtab` (String Table).
3. It finds the un-slid virtual address of `target_function`.
4. It reads `/proc/self/maps` to find where the OS actually loaded the executable in memory (`load_base`).
5. `Actual_Address = load_base + (Symbol_Address - Base_Virtual_Address_in_ELF)`.

### 2. INT3 (`0xCC`) Breakpoint Hooking
**The Problem:** How do you pause an application exactly when it hits a specific function?
**The Solution:** We use `mprotect` to make the executable code writable. We then overwrite the very first byte of the target function with `0xCC`. In x86_64 architecture, `0xCC` is the `INT3` instruction (a software breakpoint). When the CPU executes it, it halts the program and sends a `SIGTRAP` signal to the OS. Our `libckpt` intercepts the `SIGTRAP`, captures the registers via the signal's `ucontext_t`, restores the original byte over the `0xCC`, dumps the checkpoint, and then lets the program resume naturally.

### 3. The `fs_base` and Thread Local Storage (TLS)
**The Problem:** `glibc` heavily uses Thread Local Storage (TLS) to store things like `errno` and thread IDs. TLS is accessed via the `FS` segment register in x86_64. If we restore memory and standard registers but forget `fs_base`, `glibc` will crash the moment it tries to access memory relative to the `FS` register.
**The Solution:** We use the `arch_prctl(ARCH_GET_FS)` syscall to read the base pointer during the dump, and `arch_prctl(ARCH_SET_FS)` in the loader to restore it before jumping to the ROI.

### 4. Intel SDE & AVX Instruction Masking
**The Problem:** gem5 SE mode does not support many modern x86 instructions (like AVX/SSE4 `ptest`). If the host machine dumps a checkpoint where `glibc` decided to use AVX optimized routines for `memcpy`, gem5 will crash with an "Unrecognized Instruction" error upon restoration.
**The Solution:** We run the generation step under **Intel SDE** using `setarch` to spoof an older CPU architecture (Westmere). We also use the undocumented `GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"` environment variable to forcefully strip AVX/SSE4 capabilities from the runtime glibc loader, ensuring the dumped memory only contains safe, SSE2 fallback functions that gem5 understands.

---

## 4. Concepts to Study (Your Syllabus)

To fully comprehend the mechanics of what we just built, you should dedicate time to studying the following concepts. If you understand these, you will understand the entirety of modern Linux execution flows.

1. **The Linux Virtual Memory System:**
   - How Virtual Memory works (Pages, Page Tables).
   - The `mmap`, `munmap`, and `mprotect` syscalls (pay special attention to `MAP_FIXED` and `MAP_ANONYMOUS`).
   - How to read and interpret `/proc/self/maps`.

2. **The ELF File Format & Dynamic Loading:**
   - What an ELF file is (Headers, Sections, Segments).
   - The difference between `.symtab` (Symbol Table) and `.dynsym` (Dynamic Symbol Table).
   - How the OS loader (`ld-linux.so`) maps an ELF into memory.
   - Position Independent Executables (PIE) and Address Space Layout Randomization (ASLR).
   - How `LD_PRELOAD` hooks function calls.

3. **Linux Signals and Execution Contexts:**
   - How Linux handles signals (`SIGUSR1`, `SIGTRAP`, `SIGSEGV`).
   - The `sigaction` struct and the `SA_SIGINFO` flag.
   - The `ucontext_t` structure: how the kernel saves the entire CPU state (General Purpose Registers, Instruction Pointer, Stack Pointer) and passes it to your signal handler.

4. **x86_64 Assembly Basics:**
   - The primary registers: `RAX` (return value), `RDI, RSI, RDX, RCX, R8, R9` (function arguments), `RSP` (Stack Pointer), `RIP` (Instruction Pointer).
   - What the `INT3` (`0xCC`) instruction does at the hardware level.
   - The difference between inline assembly (`__asm__ volatile`) and pure assembly files (`.S`).

5. **Thread Local Storage (TLS):**
   - How variables are stored per-thread.
   - The role of the `FS` and `GS` segment registers in 64-bit mode.
   - The `arch_prctl` syscall (`ARCH_SET_FS`, `ARCH_GET_FS`).
