# Real Machine Checkpointing for gem5

This repository contains a full proof-of-concept and integration toolkit for taking memory/register checkpoints of real applications natively on x86_64 Linux and perfectly restoring them inside the **gem5 simulator** in Syscall Emulation (SE) mode.

By dynamically capturing all `vma` segments, segment selectors, CPU registers, and the `fs_base` register via an `LD_PRELOAD` interceptor, this bypasses the need for the host OS or gem5 to handle complex PIE/ASLR initialization or interpreter loading.

## Repository Structure

- `src/libckpt.c`: The core `LD_PRELOAD` dynamic library that hooks into the target process and handles capturing state. It provides three triggering modes: `SIGUSR1` (manual), `CKPT_AFTER_NS` (timed), and `CKPT_AT_SYMBOL` (automatic breakpoint at a specific function).
- `src/dumper.c` / `src/dumper_asm.S`: Handles dumping the exact CPU register state and memory maps to disk.
- `src/loader.c`: A statically linked loader used by gem5 (or natively) to load the checkpoint back into memory, properly set `fs_base`, restore registers, and jump directly to the target program's execution without using traditional `execve` boundaries.
- `run_example.sh` & `example.c`: A self-contained, simple local example.
- `Tailbench/`: Contains all our modifications to Tailbench to cleanly integrate this checkpointing logic directly into the benchmark harness.
- `run_checkpoint_sde.sh` & `run_gem5.sh`: Wrappers for safely dumping Tailbench benchmarks via Intel SDE (to mask out unsupported AVX instructions) and then simulating them inside gem5.

---

## 1. Quick Local Example (Native)

To understand exactly how this works without involving gem5, check out the provided local example. It demonstrates hooking a specific function (`target_function`) to automatically drop a checkpoint and then locally restoring it.

**Run the example:**
```bash
./run_example.sh
```

**What happens?**
1. It compiles `example.c` (a loop that counts to 10 and hits `target_function` at iteration 3).
2. It compiles `libckpt.so` and the static `loader`.
3. It launches the example natively with `LD_PRELOAD=./build/libckpt.so` and `CKPT_AT_SYMBOL=target_function`.
4. At iteration 3, `libckpt` intercepts the call, dumps `example_dump.ckpt`, and cleanly exits.
5. Finally, it uses `./build/loader example_dump.ckpt` to natively load the state back into memory. The program immediately resumes from iteration 3 and counts to 10!

---

## 2. Using it in gem5 (Tailbench)

For massive workloads like Tailbench, we have cleanly integrated the checkpointing directly into the benchmark harness (`tbench_server_integrated.cpp`). You do **not** need `LD_PRELOAD` for integrated Tailbench apps because the dumper is dynamically linked directly into the harness!

1. **Setup and compile Tailbench (via Docker to avoid host dependency issues):**
   ```bash
   ./setup_tailbench.sh
   ```

2. **Generate the checkpoint (e.g., for Silo):**
   *Note: We run this through Intel SDE and set GLIBC_TUNABLES to prevent the host's `glibc` from utilizing AVX/SSE4.1 instructions, which gem5's SE mode lacks support for.*
   ```bash
   ./run_checkpoint_sde.sh
   ```
   *This outputs `tailbench_dump.ckpt` inside `Tailbench/tailbench/silo/`.*

3. **Restore the checkpoint inside gem5:**
   Use the provided helper script, which sets up the correct memory sizing and CPU configurations.
   ```bash
   ./run_gem5.sh Tailbench/tailbench/silo/tailbench_dump.ckpt
   ```

You should see gem5 natively jump straight to the ROI (Region of Interest) and begin simulating:
```
[loader] Setting FS base and jumping to ROI
```

---

## Configuration Flags

When using `libckpt.so` via `LD_PRELOAD`, you can configure its behavior using the following environment variables:

| Variable | Description |
|---|---|
| `CKPT_OUTPUT` | Path for the generated checkpoint (default: `libckpt_dump.ckpt`). |
| `CKPT_AFTER_NS` | Automatically trigger a checkpoint after X nanoseconds of execution. |
| `CKPT_AT_SYMBOL` | Automatically trigger a checkpoint when a specific function symbol is called. Works with PIE binaries by parsing the in-process ELF `.symtab` natively. |
| `CKPT_AT_SYMBOL_CALL` | When using `CKPT_AT_SYMBOL`, wait for the N-th invocation of the function before dumping (default: `1`). |

If none of the automatic triggers are defined, `libckpt.so` falls back to waiting for a `SIGUSR1` signal.

## Architectural Notes
- **Dynamic Linking Support:** By loading the checkpoint *after* the `ld.so` interpreter has mapped all libraries, we bypass all of gem5's SE mode limitations regarding PIE binaries and ASLR.
- **`fs_base` Bypass:** Because `glibc` strictly relies on `fs_base` for TLS (Thread Local Storage), our `loader` must invoke the `ARCH_SET_FS` `arch_prctl` syscall and use `setcontext` to trick the execution context natively.
- **Pure ASM context dump:** We capture the context using pure assembly `dumper_asm.S` to prevent modern compiler optimizations or stack red-zones from corrupting the instruction pointer or stack pointer upon restoration.
