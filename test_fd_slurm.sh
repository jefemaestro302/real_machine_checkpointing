#!/bin/bash
#SBATCH --job-name=test_fd_gem5
#SBATCH --output=slurm_test_fd.out
#SBATCH --error=slurm_test_fd.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:10:00

TFM_DIR="$HOME/TFM"
GEM5_BIN="$HOME/gap_gem5/gem5/build/X86/gem5.opt"
CFG_SCRIPT="$TFM_DIR/gem5_scripts/X86/x86_st.py"
LOADER="$TFM_DIR/repositories/real_machine_checkpoint/build/loader"
TEST_DIR="$TFM_DIR/repositories/real_machine_checkpoint/test"

cd $TEST_DIR

echo "=== Building test program ==="
gcc -O2 -g -Wall -fno-stack-protector -fno-builtin -static -no-pie \
    -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 \
    -o test_fd test_fd.c ../src/dumper.c ../src/dumper_asm.S

echo "=== Setting up input files ==="
echo -n "1234567890" > input1.txt
echo -n "ABCDEFGHIJ" > input2.txt

echo "=== First Run (Dumping Natively) ==="
export GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"
./test_fd $(pwd)/input1.txt $(pwd)/output.txt

echo "=== output.txt contents after first run: ==="
cat output.txt
echo "========================================="

echo "=== Moving input1.txt to simulate file loss ==="
mkdir -p new_dir
mv input1.txt new_dir/input1.txt
rm -f output.txt

echo "=== Second Run (Restoring in gem5) ==="
export GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"

rm -rf m5out
$GEM5_BIN --outdir=m5out $CFG_SCRIPT --cmd="$LOADER" --options="dump.ckpt $(pwd)/input1.txt=$(pwd)/new_dir/input1.txt" --maxinsts=100000000 --pmudispatch --pmuissue

echo "=== output.txt should not exist (writes sinkholed) ==="
if [ -f output.txt ]; then
    echo "ERROR: output.txt was recreated! Sinkhole failed."
else
    echo "SUCCESS: output.txt was not created. Writes went to /dev/null."
fi

echo "=== Done ==="
