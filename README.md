# Real Machine Checkpointing for gem5

This repository contains a full proof-of-concept and integration toolkit for taking memory/register checkpoints of real applications natively on x86_64 Linux and perfectly restoring them inside the **gem5 simulator** in Syscall Emulation (SE) mode.

By compiling applications **statically against musl libc**, we completely bypass `glibc`'s dynamic IFUNC (CPUID) dispatch. This guarantees that no AVX instructions leak into the checkpoint, permanently resolving the `Unrecognized/invalid instruction executed` panics in gem5's `DerivO3CPU`.

## Repository Structure

- `src/libckpt.c`: The core checkpoint library. It provides three triggering modes: `SIGUSR1` (manual), `CKPT_AFTER_NS` (timed), and `CKPT_AT_SYMBOL` (automatic breakpoint at a specific function).
- `src/dumper.c` / `src/dumper_asm.S`: Handles dumping the exact CPU register state and memory maps to disk.
- `src/loader.c`: A statically linked loader used by gem5 (or natively) to load the checkpoint back into memory, properly set `fs_base`, restore registers, and jump directly to the target program's execution without using traditional `execve` boundaries.
- `compile_in_docker.sh`: A helper script that builds the static `libckpt` and `loader` inside a clean, Alpine-based `musl` Docker container.

---

## 1. Quick Start: Compiling the Checkpoint Infrastructure

To ensure that no host machine AVX capabilities leak into your gem5 checkpoints, we use an Alpine Linux Docker container with `musl-gcc`.

1. **Build the checkpoint infrastructure:**
   ```bash
   ./compile_in_docker.sh
   ```

2. **What this does:**
   - Builds the `musl_builder` Docker image from `docker/Dockerfile.musl`.
   - Compiles `src/loader.c` statically (placed at `build/loader`).
   - Compiles `src/libckpt.c` and `src/dumper.c` into a single, relocatable object: `build/libckpt_static.o`.

---

## 2. Compiling Your Application

To checkpoint *any* application seamlessly:

1. You must compile your application **statically** using the `musl_builder` Docker container (to avoid `glibc` AVX leakage).
2. You must link against the `build/libckpt_static.o` object file we generated in Step 1.

**Example Command (assuming your app is in `./my_app_dir`):**
```bash
docker run --rm -v "$(pwd)/my_app_dir":/app -v "$(pwd)/build":/ckpt_build -w /app musl_builder \
    gcc -O2 -static -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 \
    -o my_app my_app.c /ckpt_build/libckpt_static.o -lpthread
```

---

## 3. Generating a Checkpoint Natively

Run your statically-linked application directly on your host machine. The `libckpt_static.o` constructor will automatically initialize itself.

By default, the library expects a `SIGUSR1` signal to trigger a dump, or you can use environment variables:

```bash
# Example: Dump checkpoint after 500,000,000 nanoseconds (0.5 seconds)
CKPT_OUTPUT=dump.ckpt CKPT_AFTER_NS=500000000 ./my_app_dir/my_app
```

When the trigger fires, the process state will be dumped to `dump.ckpt`, and the application will cleanly exit.

---

## 4. Restoring in gem5

Once you have your `dump.ckpt`, you can restore it directly inside gem5 using the custom `loader` we built. The loader handles setting up the memory mappings and `fs_base` before jumping to the Region of Interest (ROI).

```bash
/path/to/gem5.opt --outdir=m5out x86_st.py \
    --cmd=./build/loader \
    --options="dump.ckpt" \
    --maxinsts=100000000
```

You should see gem5 jump straight to your application's state and begin simulating:
```
[loader] Setting FS base and jumping to ROI
```

---

## Configuration Flags

When running your compiled binary, you can configure the checkpoint library's behavior using the following environment variables:

| Variable | Description |
|---|---|
| `CKPT_OUTPUT` | Path for the generated checkpoint (default: `libckpt_dump.ckpt`). |
| `CKPT_AFTER_NS` | Automatically trigger a checkpoint after X nanoseconds of execution via a background timer thread. |
| `CKPT_AT_SYMBOL` | Automatically trigger a checkpoint when a specific function symbol is called. Works by parsing the in-process ELF `.symtab` natively. |
| `CKPT_AT_SYMBOL_CALL` | When using `CKPT_AT_SYMBOL`, wait for the N-th invocation of the function before dumping (default: `1`). |

If none of the automatic triggers are defined, `libckpt` falls back to waiting for a `SIGUSR1` signal.

## Architectural Notes
- **Static Checkpointing:** Previous versions of this repo used `LD_PRELOAD` with `glibc`. This has been completely removed in favor of static compilation with `musl`, which is much cleaner and totally eliminates `IFUNC` AVX dynamic leakage.
- **`fs_base` Bypass:** The `loader` must invoke the `ARCH_SET_FS` `arch_prctl` syscall and use a small assembly stub to trick the execution context natively to restore Thread Local Storage.
- **Pure ASM context dump:** We capture the context using pure assembly `dumper_asm.S` to prevent modern compiler optimizations or stack red-zones from corrupting the instruction pointer or stack pointer upon restoration.
