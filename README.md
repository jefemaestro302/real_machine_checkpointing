# Real Machine Checkpointing for gem5

This repository contains a full proof-of-concept and integration toolkit for taking memory/register checkpoints of real applications natively on x86_64 Linux and perfectly restoring them inside the **gem5 simulator** in Syscall Emulation (SE) mode.

By dynamically capturing all `vma` segments, segment selectors, CPU registers, and the `fs_base` register via an `LD_PRELOAD` interceptor, this bypasses the need for the host OS or gem5 to handle complex PIE/ASLR initialization or interpreter loading.

## Repository Structure

- `src/libckpt.c`: The core `LD_PRELOAD` dynamic library that hooks into the target process and handles capturing state. It provides three triggering modes: `SIGUSR1` (manual), `CKPT_AFTER_NS` (timed), and `CKPT_AT_SYMBOL` (automatic breakpoint at a specific function).
- `src/dumper.c` / `src/dumper_asm.S`: Handles dumping the exact CPU register state and memory maps to disk.
- `src/loader.c`: A statically linked loader used by gem5 (or natively) to load the checkpoint back into memory, properly set `fs_base`, restore registers, and jump directly to the target program's execution without using traditional `execve` boundaries.
- `run_example.sh` & `example.c`: A self-contained, simple local example.
- `run_gem5.sh`: Wrapper for simulating dumped checkpoints inside gem5.
- `run_noavx_glibc_checkpoint.sh`: Full workflow for generating a gem5-compatible checkpoint of Tailbench Silo using a glibc compiled with --disable-multi-arch.
- `generate_all_checkpoints_noavx.sh`: A script that leverages a custom Docker container to natively generate AVX-clean checkpoints for the entire Tailbench suite (masstree, moses, shore, silo, sphinx, xapian, img-dnn).
- `run_tailbench_timed.sh`: A local-only script to demonstrate running a Tailbench benchmark with a timed checkpoint.

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

## 2. Checkpointing Any Application for gem5 (The AVX Solution)

You can use `libckpt.so` to checkpoint any application, and then load it into gem5. However, gem5's SE mode lacks support for many modern x86 instructions (like AVX2 `PBROADCASTB` or AVX-512). If you generate a checkpoint natively on a modern host, two things will crash gem5:
1. Your compiler generating AVX instructions for your application code.
2. `glibc` dynamically resolving its optimized routines (e.g., `memcpy`) to use AVX instructions using `IFUNC` CPUID dispatch at startup.

To successfully checkpoint an application for gem5, you must follow these 3 steps:

### Step 1: Compile your application without AVX
Ensure your application's `Makefile` or build system uses the following C/C++ flags to prevent the compiler from generating AVX instructions:
```bash
CFLAGS="-mno-avx -mno-avx2 -mno-avx512f"
CXXFLAGS="-mno-avx -mno-avx2 -mno-avx512f"
```

### Step 2: Build the No-AVX glibc Docker Environment
To cleanly bypass the `IFUNC` dynamic dispatch in system libraries, we use a Docker environment that contains `glibc 2.35` compiled from source with the `--disable-multi-arch` flag. This completely strips AVX instructions from the C library.

```bash
# Build the provided docker image
docker build -t tailbench_noavx_glibc -f docker/Dockerfile.noavx_glibc .
```

### Step 3: Run and Checkpoint Inside Docker
Launch your application *inside* the Docker container, executing it through the custom dynamic linker so it uses the AVX-free glibc instead of the host's system glibc.

```bash
# Example: Taking a checkpoint after 3 seconds (3,000,000,000 ns)
docker run -it --rm --privileged -v "$(pwd)":/workspace tailbench_noavx_glibc /bin/bash -c "
  cd /workspace && \
  /opt/glibc-noavx/lib/ld-linux-x86-64.so.2 \
      --library-path \"/opt/glibc-noavx/lib:/lib/x86_64-linux-gnu\" \
      env LD_PRELOAD=./build/libckpt.so CKPT_AFTER_NS=3000000000 \
      ./my_application
"
```

### Step 4: Simulate in gem5
Once you have the `.ckpt` file (generated with AVX disabled), run it natively in gem5 using our helper script:
```bash
./run_gem5.sh my_application_dump.ckpt --cpu o3 --maxinsts 10000000
```

You should see gem5 jump straight to your application's state and begin simulating:
```
[loader] Setting FS base and jumping to ROI
```

---

## Tailbench Suite Status

We have extensively tested this pipeline with the **Tailbench v0.9** suite. By combining application-level `-mno-avx` compiler flags and our `glibc --disable-multi-arch` environment, the following applications run flawlessly in gem5 O3CPU:

* ✅ **masstree**
* ✅ **moses**
* ✅ **shore**
* ✅ **silo**
* ✅ **xapian**
* ✅ **img-dnn**

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
