#!/bin/bash
# ==============================================================================
# Script to copy SDV locally and compile statically inside Docker
# ==============================================================================

CONTAINER_NAME="tailbench_compiler"
TFM_ROOT=$(readlink -f $(pwd)/..)
REPOS_DIR="${TFM_ROOT}/Repos"
SDV_DIR="${REPOS_DIR}/sdv"
GEM5_HEADERS_DIR="$(pwd)/gem5_headers"

echo "1. Ensuring SDV is inside Repos..."
if [ ! -d "$SDV_DIR" ]; then
    echo "Copying SDV from /home/daniel/vbox/sdv..."
    mkdir -p "$SDV_DIR"
    cp -r /home/daniel/vbox/sdv/* "$SDV_DIR/"
fi

echo "2. Rebuilding the Docker container..."
docker build -t ${CONTAINER_NAME} .

echo "3. Running the SDV compilation inside Docker..."
docker run --rm -i \
    -v "${SDV_DIR}:/sdv" \
    -v "${GEM5_HEADERS_DIR}:/gem5_headers" \
    ${CONTAINER_NAME} \
    /bin/bash << 'EOF'

cd /sdv/vision
# Force static compilation globally for SDV
export CFLAGS="-static -O3"
export CXXFLAGS="-static -O3"
export LDFLAGS="-static -static-libgcc -static-libstdc++"

echo "Compiling SDV..."
make CROSS_COMPILE="" clean
make CROSS_COMPILE="" compile

EOF

echo "4. Syncing compiled SDV benchmarks (binaries & datasets) to the cluster..."
mkdir -p "${TFM_ROOT}/workloads/sdv"
# Copy the benchmarks directory to workloads/sdv, excluding src/ and matlab/ directories
rsync -av --exclude='src/' --exclude='matlab/' "${SDV_DIR}/vision/benchmarks" "${TFM_ROOT}/workloads/sdv/"
# Sync workloads/sdv to the cluster
scp -P 3322 -r "${TFM_ROOT}/workloads/sdv/benchmarks" descrom@upvnet.upv.es@altek1.gap.upv.es:/mnt/beegfs/gap/descrom@upvnet.upv.es/TFM/workloads/sdv/

echo "✅ SDV successfully compiled and deployed!"
