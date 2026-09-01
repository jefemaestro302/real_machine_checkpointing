#!/bin/bash
set -e

# Build the checkpoint library object files
echo "=== Building checkpoint library in Docker ==="
docker run --rm \
    -v $(pwd):/workspace \
    gem5_noavx_env:latest \
    /bin/bash -c "cd /workspace && \
    mkdir -p build && \
    gcc -c -O2 -g -Wall -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 -fno-stack-protector -fno-builtin src/dumper.c -o build/dumper.o && \
    gcc -c -O2 -g -Wall -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 -fno-stack-protector -fno-builtin src/dumper_asm.S -o build/dumper_asm.o && \
    gcc -c -O2 -g -Wall -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 -fno-stack-protector -fno-builtin src/libckpt.c -o build/libckpt.o && \
    echo 'Library objects successfully compiled to build/'"

# Build the SPEC benchmark
echo "=== Building SPEC perlbench_r in Docker ==="
docker run --rm \
    -v $(pwd):/workspace \
    -v $(pwd)/specs:/spec2017 \
    gem5_noavx_env:latest \
    /bin/bash -c "cd /spec2017 && \
    source shrc && \
    runcpu --config=gem5_noavx.cfg --action=build 500.perlbench_r"

echo "=== SPEC Build Finished! ==="
