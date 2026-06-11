#!/bin/bash

# This is a local-only script to demonstrate how to run a Tailbench benchmark 
# with a 3.21 second timed checkpoint using our generic library approach.

echo "==========================================="
echo "  Tailbench 3.21s Timed Checkpoint         "
echo "==========================================="

docker run --rm --privileged -v $(pwd):/workspace tailbench_compiler /bin/bash -c '
# Ensure SDE is downloaded
if [ ! -f "/workspace/Tailbench/sde/sde64" ]; then
    echo "[*] Downloading Intel SDE..."
    INTEL_SDE_URL="https://downloadmirror.intel.com/915934/sde-external-10.8.0-2026-03-15-lin.tar.xz"
    wget -q --no-check-certificate -O /workspace/Tailbench/intel-sde.tar.xz "$INTEL_SDE_URL"
    apt-get update >/dev/null 2>&1 && apt-get install -y xz-utils >/dev/null 2>&1
    mkdir -p /workspace/Tailbench/sde
    tar -xf /workspace/Tailbench/intel-sde.tar.xz -C /workspace/Tailbench/sde --strip-components=1
fi

echo "[1] Compiling libckpt.so, libnoavx.so, harness, and Silo (to ensure a clean build)..."
gcc -fPIC -shared -O3 -mno-avx -mno-avx2 -o /workspace/build/libnoavx.so /workspace/src/libnoavx.c
gcc -fPIC -shared -o /workspace/build/libckpt.so /workspace/src/libckpt.c /workspace/src/dumper.c -ldl
cd /workspace/Tailbench/tailbench/harness && make clean && make
cd /workspace/Tailbench/tailbench/silo && make clean && ./build.sh

echo "[2] Running Silo to generate checkpoint NATIVELY..."
# We inject our generic libckpt.so via LD_PRELOAD and intercept tBenchRecvReq.
# We disabled AVX inside the Makefiles, and use libnoavx.so to override glibc AVX IFUNCs.

LD_LIBRARY_PATH=./third-party/lz4 \
TBENCH_QPS=10 \
TBENCH_MAXREQS=15 \
TBENCH_WARMUPREQS=10 \
GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F:glibc.tune.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F:glibc.tune.hwcap_mask=0" \
LD_HWCAP_MASK=0x1 \
setarch x86_64 -R \
    env LD_PRELOAD=/workspace/build/libnoavx.so:/workspace/build/libckpt.so CKPT_AT_SYMBOL=tBenchRecvReq CKPT_AT_SYMBOL_CALL=10 CKPT_OUTPUT=tailbench_native_dump.ckpt \
    ./out-perf.masstree/benchmarks/dbtest_integrated --bench tpcc --num-threads 1 --scale-factor 1 --retry-aborted-transactions --ops-per-worker 1000
'

echo "[+] Done! You should now have Tailbench/tailbench/silo/tailbench_native_dump.ckpt"
