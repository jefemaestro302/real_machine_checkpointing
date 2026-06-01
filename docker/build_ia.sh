#!/bin/bash
# ==============================================================================
# Script to compile IA apps statically using the Docker Compile_enviroment
# ==============================================================================

CONTAINER_NAME="tailbench_compiler"
TFM_ROOT=$(readlink -f $(pwd)/..)
REPOS_DIR="${TFM_ROOT}/Repos"
IA_DIR="${REPOS_DIR}/ml_gem5_benchmarks"
GEM5_HEADERS_DIR="$(pwd)/gem5_headers"

echo "1. Checking/Fetching gem5 headers and libm5.a..."
mkdir -p "${GEM5_HEADERS_DIR}/util/m5/build/x86/out"
if [ ! -d "${GEM5_HEADERS_DIR}/include" ] || [ ! -f "${GEM5_HEADERS_DIR}/util/m5/build/x86/out/libm5.a" ]; then
    echo "Files missing, copying from the cluster..."
    scp -P 3322 -r descrom@upvnet.upv.es@altek1.gap.upv.es:/mnt/beegfs/gap/descrom@upvnet.upv.es/gap_gem5/gem5/include "${GEM5_HEADERS_DIR}/"
    scp -P 3322 descrom@upvnet.upv.es@altek1.gap.upv.es:/mnt/beegfs/gap/descrom@upvnet.upv.es/gap_gem5/gem5/util/m5/build/x86/out/libm5.a "${GEM5_HEADERS_DIR}/util/m5/build/x86/out/"
else
    echo "gem5 headers and libm5.a already present locally, skipping scp."
fi

echo "2. Rebuilding the Docker container (ensuring scikit-learn is installed)..."
docker build -t ${CONTAINER_NAME} .

echo "3. Running the IA apps compilation inside Docker..."
docker run --rm -i \
    -v "${IA_DIR}:/ia_apps" \
    -v "${GEM5_HEADERS_DIR}:/gem5_headers" \
    ${CONTAINER_NAME} \
    /bin/bash << 'EOF'

cd /ia_apps
# Override the GEM5_DIR to point to our mounted gem5 headers
export GEM5_DIR_OVERRIDE="/gem5_headers"
# Set Python IO encoding to UTF-8 to prevent print crash on accented characters
export PYTHONIOENCODING=utf-8

echo "Configuring and compiling all IA apps statically..."
chmod +x scripts/compile_with_gem5ops.sh
./scripts/compile_with_gem5ops.sh --all

EOF

echo "4. Syncing compiled IA binaries to the cluster..."
mkdir -p "${TFM_ROOT}/workloads/ia_apps"
cp -r "${IA_DIR}/3_bin/"* "${TFM_ROOT}/workloads/ia_apps/"
scp -P 3322 -r "${TFM_ROOT}/workloads/ia_apps/"* descrom@upvnet.upv.es@altek1.gap.upv.es:/mnt/beegfs/gap/descrom@upvnet.upv.es/TFM/workloads/ia_apps/

echo "✅ IA Apps successfully compiled and deployed!"
