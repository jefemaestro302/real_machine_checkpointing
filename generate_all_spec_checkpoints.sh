#!/bin/bash
set -e

# 1. Rebuild our checkpointing library to apply the new dynamic output logic
echo "=== Rebuilding libckpt inside Docker ==="
docker run --rm -v $(pwd):/workspace gem5_noavx_env:latest \
    /bin/bash -c "cd /workspace && make clean && make"

# List of integer benchmarks in SPEC CPU2017 (add or remove as needed)
BENCHMARKS=(
    "500.perlbench_r"
)

echo "=== Generating SPEC Checkpoints natively in Docker ==="

docker run -i --rm \
    -v $(pwd):/workspace \
    -v $(pwd)/specs:/spec2017 \
    gem5_noavx_env:latest \
    /bin/bash << 'EOF'
set -e
cd /spec2017
source shrc
BENCHMARKS=(
    "502.gcc_r"
    "505.mcf_r"
    "519.lbm_r"
)
for bench in ${BENCHMARKS[*]}; do
    echo "=================================================="
    echo "   Processing $bench"
    echo "=================================================="
    
    # Build the benchmark natively with the gem5_noavx.cfg
    runcpu --config=gem5_noavx.cfg --action=build $bench
    
    # Run it (the early checkpoint exit will trigger a non-zero exit code, so we catch it with || true)
    runcpu --config=gem5_noavx.cfg --action=run --size=train --iterations=1 $bench || true
    
    # Find the dynamically generated dump files and copy them to the main workspace
    echo "Copying checkpoints for $bench..."
    find /spec2017/benchspec/CPU/$bench/run/ -name 'dump_*.ckpt' -exec cp {} /workspace/ \;
done
EOF

echo "=== All Checkpoints Generated and Extracted to Workspace! ==="
