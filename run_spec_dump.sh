#!/bin/bash
set -e

echo "=== Running SPEC perlbench_r natively in Docker to generate checkpoint ==="
docker run --rm \
    -v $(pwd):/workspace \
    -v $(pwd)/specs:/spec2017 \
    -e CKPT_AFTER_NS=2000000000 \
    -e CKPT_OUTPUT=/workspace/dump_perlbench.ckpt \
    gem5_noavx_env:latest \
    /bin/bash -c "cd /spec2017/benchspec/CPU/500.perlbench_r/run/run_base_train_test_compilacion-m64.0000 && \
    echo 'Running manual command...' && \
    ../run_base_train_test_compilacion-m64.0000/perlbench_r_base.test_compilacion-m64 -I. -I./lib diffmail.pl 2 550 15 24 23 100 > diffmail.2.550.15.24.23.100.out 2> diffmail.2.550.15.24.23.100.err || echo 'Exited successfully with early checkpoint termination'"

echo "=== Dump process complete! Check if dump_perlbench.ckpt exists in workspace. ==="
