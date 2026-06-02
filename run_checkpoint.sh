#!/bin/bash
echo "[*] Generating checkpoint with AVX instructions masked..."
export GLIBC_TUNABLES="glibc.cpu.hwcaps=-AVX512F,-AVX2,-AVX"

docker run --rm -it --privileged -v $(pwd)/Tailbench:/tailbench \
    -e GLIBC_TUNABLES="glibc.cpu.hwcaps=-AVX512F,-AVX2,-AVX" \
    tailbench_compiler /bin/bash -c "
cd /tailbench/tailbench/silo && \
gcc -O3 -shared -fPIC -fno-builtin -mno-avx -mno-sse /tailbench/no_avx_string.c -o /tailbench/no_avx_string.so && \
LD_PRELOAD=/tailbench/no_avx_string.so \
LD_LIBRARY_PATH=./third-party/lz4 \
TBENCH_QPS=10 \
TBENCH_MAXREQS=10 \
TBENCH_WARMUPREQS=10 \
setarch x86_64 -R env LD_HWCAP_MASK=0x0 \
./out-perf.masstree/benchmarks/dbtest_integrated --bench tpcc --num-threads 1 --scale-factor 1 --retry-aborted-transactions --ops-per-worker 1000
"

echo "[+] Done!"
