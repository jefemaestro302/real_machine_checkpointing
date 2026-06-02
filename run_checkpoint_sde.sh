#!/bin/bash

echo "==========================================="
echo "  Generating checkpoint using Intel SDE    "
echo "==========================================="

docker run --rm --privileged -v $(pwd)/Tailbench:/tailbench tailbench_compiler /bin/bash -c '
cd /tailbench/tailbench/silo

if [ ! -f "/tailbench/sde/sde64" ]; then
    rm -rf /tailbench/sde
    echo "[*] Downloading Intel SDE..."
    INTEL_SDE_URL="https://downloadmirror.intel.com/915934/sde-external-10.8.0-2026-03-15-lin.tar.xz"
    echo "Downloading from: $INTEL_SDE_URL"
    wget -q --no-check-certificate -O /tailbench/intel-sde.tar.xz "$INTEL_SDE_URL"
    echo "[*] Extracting Intel SDE..."
    apt-get update >/dev/null 2>&1 && apt-get install -y xz-utils >/dev/null 2>&1
    mkdir -p /tailbench/sde
    tar -xf /tailbench/intel-sde.tar.xz -C /tailbench/sde --strip-components=1
fi

echo "[*] Recompiling Tailbench with updated dumper..."
cd /tailbench/tailbench/harness && make
cd /tailbench/tailbench/silo && ./build.sh

echo "[*] Launching target app via Intel SDE (Spoofing Westmere CPU without AVX)..."
LD_LIBRARY_PATH=./third-party/lz4 \
TBENCH_QPS=10 \
TBENCH_MAXREQS=10 \
TBENCH_WARMUPREQS=10 \
setarch x86_64 -R /tailbench/sde/sde64 -wsm -- ./out-perf.masstree/benchmarks/dbtest_integrated --bench tpcc --num-threads 1 --scale-factor 1 --retry-aborted-transactions --ops-per-worker 1000
'

echo "[+] Done!"
