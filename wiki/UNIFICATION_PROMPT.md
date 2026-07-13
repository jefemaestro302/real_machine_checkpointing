# Task: Unify Checkpointing Architecture (Dynamic Approach)

**Context:**
We have a tool for "Real Machine Checkpointing for gem5" that intercepts a process natively on Linux, dumps its state (memory, CPU, file descriptors), and restores it inside the gem5 simulator (Syscall Emulation mode). 

Currently, the tool operates using a split architecture depending on the workload:
1. **For Tailbench:** It uses a generalist **dynamic** approach. The application is compiled normally (PIE/Dynamic). We intercept it by using a custom AVX-free `glibc` linker and injecting our tool via `LD_PRELOAD=libckpt.so`.
2. **For SPEC 2017:** It uses a rigid **static** approach. The benchmark is compiled statically (`-static`), and our tool's object files (`libckpt.o`, `dumper.o`) are injected directly into the SPEC binary via linker flags (`EXTRA_LIBS` in `gem5_noavx.cfg`). 

**The Goal:**
We want to achieve architectural homogeneity. The dynamic approach (`LD_PRELOAD`) is vastly superior because it is completely generalist—it can instrument *any* standard Linux binary without modifying its build system. 

Your objective is to port the SPEC 2017 workflow to use the standard dynamic approach, completely removing the static compilation hacks.

**Actionable Steps:**
1. **Modify the SPEC Configuration:**
   - Open `specs/config/gem5_noavx.cfg`.
   - Locate the `EXTRA_LDFLAGS = -static` and remove it.
   - Locate the `EXTRA_LIBS = -Wl,--whole-archive /workspace/build/libckpt.o ...` and remove it entirely.
   - Ensure SPEC compiles as a standard dynamic PIE executable.

2. **Update the Execution Scripts:**
   - Open `run_spec_dump.sh` (and any related SPEC dumping scripts).
   - Currently, they run the SPEC binary natively: `./perlbench_r_base...`
   - You must modify this execution line to wrap the benchmark in our custom dynamic linker and inject the `LD_PRELOAD`, exactly like the Tailbench workflow does.
   - Example wrapper to implement:
     ```bash
     /opt/glibc-noavx/lib/ld-linux-x86-64.so.2 \
         --library-path "/opt/glibc-noavx/lib:/lib/x86_64-linux-gnu" \
         env LD_PRELOAD=/workspace/build/libckpt.so CKPT_AFTER_NS=2000000000 \
         ./perlbench_r_base.test_compilacion-m64 -I. -I./lib diffmail.pl ...
     ```

3. **Validation & Testing:**
   - Execute the modified `run_spec_dump.sh` to generate the `.ckpt` file.
   - Use the `loader` to restore this checkpoint inside gem5.
   - Ensure that the file descriptor mapping and general execution continue flawlessly just as they did with the static version.

Please provide the updated `gem5_noavx.cfg` and the modified bash scripts to achieve this.
