#!/bin/bash
set -e

echo "=== Building test program ==="
gcc -O2 -g -Wall -fno-stack-protector -fno-builtin -static -no-pie \
    -o test_fd test_fd.c ../src/dumper.c ../src/dumper_asm.S

echo "=== Setting up input files ==="
echo -n "1234567890" > input1.txt
echo -n "ABCDEFGHIJ" > input2.txt

echo "=== First Run (Dumping) ==="
./test_fd $(pwd)/input1.txt $(pwd)/output.txt

echo "=== output.txt contents after first run: ==="
cat output.txt
echo "========================================="

echo "=== Moving input1.txt to simulate file loss (different directory) ==="
mkdir -p new_dir
mv input1.txt new_dir/input1.txt
rm output.txt

echo "=== Second Run (Restoring) ==="
echo "Providing new_dir/input1.txt as the new remapped file"

# Make sure loader is built
make -C .. build/loader >/dev/null 2>&1

../build/loader dump.ckpt $(pwd)/new_dir/input1.txt

echo "=== output.txt should not exist (writes sinkholed) ==="
if [ -f output.txt ]; then
    echo "ERROR: output.txt was recreated! Sinkhole failed."
else
    echo "SUCCESS: output.txt was not created. Writes went to /dev/null."
fi

echo "=== Cleanup ==="
rm dump.ckpt input1_old.txt input2.txt test_fd
