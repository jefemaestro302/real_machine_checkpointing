# Real Machine Checkpointing for gem5

This repository contains a full proof-of-concept and integration toolkit for taking memory/register checkpoints of real applications natively on x86_64 Linux and perfectly restoring them inside the **gem5 simulator** in Syscall Emulation (SE) mode.

By dynamically capturing all `vma` segments, segment selectors, CPU registers, and the `fs_base` register, this bypasses the need for the host OS or gem5 to handle complex PIE/ASLR initialization.

## Repository Structure

- `src/`: The core checkpoint logic. Includes `dumper.c`/`dumper_asm.S` for natively capturing the memory state, and `loader.c` for injecting the memory state back into the gem5 simulator.
- `Makefile`: A standalone test environment that builds a dummy `target_app` and `loader` to test the checkpoint mechanism without compiling heavy applications.
- `patches/`: Contains `tailbench_checkpoint.patch` to seamlessly integrate the checkpointing harness into the official Tailbench benchmarks.
- `docker/`: A reproducible environment for compiling Tailbench to avoid dependency conflicts on modern OS versions.
- `setup_tailbench.sh`: An automated script that clones Tailbench, applies our patch, and builds everything securely inside Docker.

## 1. Trying the Simple Proof-of-Concept

To verify that your gem5 environment works with our raw memory loading technique:

1. **Build the PoC:**
   ```bash
   make all
   ```
2. **Generate the dummy checkpoint:**
   *(Run natively with ASLR disabled so the addresses are fixed)*
   ```bash
   setarch x86_64 -R ./build/target_app /tmp/my_dump.ckpt
   ```
3. **Restore inside gem5:**
   ```bash
   path/to/gem5.opt path/to/se.py -c build/loader -o "/tmp/my_dump.ckpt"
   ```
   You should see `[target] === ROI PHASE DONE ===` output from the simulator!

## 2. Testing the Massive Tailbench Integration

Instead of trying to compile Tailbench with static libraries (which fundamentally breaks Silo's build system), we modified the harness to dynamically capture loaded shared libraries (like `libc`, `jemalloc`, `lz4`) natively.

1. **Setup and compile:**
   ```bash
   ./setup_tailbench.sh
   ```
2. **Generate the Tailbench Silo checkpoint:**
   ```bash
   cd Tailbench/tailbench/silo
   LD_LIBRARY_PATH=./third-party/lz4 \
   TBENCH_QPS=10 \
   TBENCH_MAXREQS=10 \
   TBENCH_WARMUPREQS=10 \
   setarch x86_64 -R ./out-perf.masstree/benchmarks/dbtest_integrated \
     --bench tpcc --num-threads 1 --scale-factor 1 \
     --retry-aborted-transactions --ops-per-worker 1000
   ```
   *This will generate a massive ~277 MB `tailbench_dump.ckpt`.*

3. **Simulate the Tailbench ROI in gem5:**
   ```bash
   # From your gem5 directory
   build/X86/gem5.opt configs/deprecated/example/se.py \
     -c /path/to/real_machine_checkpoint/build/loader \
     -o "/path/to/real_machine_checkpoint/Tailbench/tailbench/silo/tailbench_dump.ckpt"
   ```

## Key Architectural Decisions
- **Dynamic Linking:** We abandoned forced static linking in favor of dynamically linking Tailbench but taking the checkpoint *after* the `ld.so` interpreter has completely mapped the libraries.
- **`fs_base` Bypass:** Because `glibc` strictly relies on `fs_base` for TLS (Thread Local Storage), our `loader` must invoke the `ARCH_SET_FS` `arch_prctl` syscall and use `setcontext` to trick the execution context without triggering a standard function prologue.
- **Naked Functions vs Pure ASM:** We initially used `__attribute__((naked))` for the `ckpt_dump` function. Because GCC completely changed how naked attributes behave in modern x86_64 versions, we moved the capture logic to pure `dumper_asm.S` to prevent the stack pointer from corrupting the return address.
