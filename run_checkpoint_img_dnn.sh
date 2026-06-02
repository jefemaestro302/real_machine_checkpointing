#!/bin/bash

echo "==========================================="
echo "  Generating checkpoint for img-dnn        "
echo "==========================================="

DATA_DIR="/home/daniel/Curso_202526/TFM/Repos/Tailbench/tailbench.inputs"

docker run --rm --privileged \
    -v $(pwd)/Tailbench:/tailbench \
    -v ${DATA_DIR}:/inputs \
    tailbench_compiler /bin/bash -c '

# Make sure SDE is there
if [ ! -f "/tailbench/sde/sde64" ]; then
    rm -rf /tailbench/sde
    echo "[*] Downloading Intel SDE..."
    INTEL_SDE_URL="https://downloadmirror.intel.com/915934/sde-external-10.8.0-2026-03-15-lin.tar.xz"
    wget -q --no-check-certificate -O /tailbench/intel-sde.tar.xz "$INTEL_SDE_URL"
    apt-get update >/dev/null 2>&1 && apt-get install -y xz-utils >/dev/null 2>&1
    mkdir -p /tailbench/sde
    tar -xf /tailbench/intel-sde.tar.xz -C /tailbench/sde --strip-components=1
fi

echo "[*] Recompiling harness and img-dnn..."
cd /tailbench/tailbench/harness && make
cd /tailbench/tailbench/img-dnn && make

echo "[*] Launching img-dnn via Intel SDE (Spoofing Westmere, SSE2-only glibc paths)..."
TBENCH_QPS=500 \
TBENCH_MAXREQS=50 \
TBENCH_WARMUPREQS=10 \
TBENCH_MINSLEEPNS=10000 \
TBENCH_MNIST_DIR=/inputs/img-dnn/mnist \
GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F" \
setarch x86_64 -R /tailbench/sde/sde64 -wsm -- \
    ./img-dnn_integrated -r 1 -f /inputs/img-dnn/models/model.xml -n 100000000
'

echo "[+] Done!"
