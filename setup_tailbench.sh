#!/bin/bash
set -e

echo "==========================================="
echo "  Setting up Tailbench for Checkpointing   "
echo "==========================================="

# 1. Clone Tailbench if it doesn't exist
if [ ! -d "Tailbench" ]; then
    echo "[*] Cloning official Tailbench repository..."
    git clone https://github.com/mit-csail/tailbench.git Tailbench
else
    echo "[*] Tailbench directory already exists. Skipping clone."
fi

# 2. Apply our checkpoint patch
echo "[*] Applying the checkpoint integration patch..."
cd Tailbench
if git apply --check ../patches/tailbench_checkpoint.patch; then
    git apply ../patches/tailbench_checkpoint.patch
    echo "[+] Patch applied successfully!"
else
    echo "[!] Patch already applied or cannot be applied cleanly."
fi
cd ..

# 3. Build the Docker environment
echo "[*] Building Tailbench Docker compilation environment..."
cd docker
./build_docker.sh
cd ..

# 4. Compile Tailbench Harness and Silo inside Docker
echo "[*] Compiling Tailbench Harness and Silo dynamically..."
docker run --rm -i \
    -v $(pwd)/Tailbench:/tailbench \
    tailbench_compiler \
    /bin/bash -c '
echo "Configurando entorno Tailbench..."
REAL_JDK=$(dirname $(dirname $(readlink -f /usr/bin/javac)))
echo "JDK_PATH=$REAL_JDK" > /tailbench/tailbench/Makefile.config
echo "DOCKER_CXXFLAGS=-O3 -g -msse2 -mno-avx -mno-avx2 -mno-avx512f -fpermissive" >> /tailbench/tailbench/Makefile.config
echo "DOCKER_LDFLAGS=" >> /tailbench/tailbench/Makefile.config

cd /tailbench/tailbench
./clean.sh
echo "Building harness and silo dynamically..."
./build.sh harness silo
'

echo "==========================================="
echo "  Tailbench is fully patched and compiled! "
echo "==========================================="
echo "To generate a checkpoint natively, run:"
echo "cd Tailbench/tailbench/silo && LD_LIBRARY_PATH=./third-party/lz4 TBENCH_QPS=10 TBENCH_MAXREQS=10 TBENCH_WARMUPREQS=10 setarch x86_64 -R ./out-perf.masstree/benchmarks/dbtest_integrated --bench tpcc --num-threads 1 --scale-factor 1 --retry-aborted-transactions --ops-per-worker 1000"
