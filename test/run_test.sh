#!/bin/bash
# run_test.sh - Native end-to-end test of file-descriptor checkpoint/restore.
#
# Dumps test_fd (reads 5 bytes of input1.txt, writes to output.txt), moves
# input1.txt somewhere else, and restores with a path remap. The restored
# process must continue reading at offset 5 from the moved file, and its
# writes must be sinkholed (output.txt is not recreated).
#
# Runs on the host (loader --native): no gem5 needed. Everything happens in
# a temporary directory; the repository is left untouched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
NORAND="setarch -R"
$NORAND true 2>/dev/null || NORAND=""

make -C "$REPO" build/loader >/dev/null
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

echo "=== Building test program ==="
gcc -O2 -g -Wall -fno-stack-protector -fno-builtin -static -no-pie \
    -o test_fd "$HERE/test_fd.c" "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"

printf 1234567890 > input1.txt

echo "=== First run (dumping) ==="
$NORAND ./test_fd "$WORK/input1.txt" "$WORK/output.txt" > run1.log 2> dump.log
cat run1.log
[ -f dump.ckpt ] || { echo "FAIL: dump.ckpt not created"; exit 1; }

echo "=== Moving input1.txt and removing output.txt ==="
mkdir new_dir
mv input1.txt new_dir/input1.txt
rm output.txt

echo "=== Second run (restoring with remap) ==="
$NORAND "$REPO/build/loader" dump.ckpt --native \
    "$WORK/input1.txt=$WORK/new_dir/input1.txt" > run2.log 2> loader.log
cat run2.log

fail=0
grep -q "Restored from dump" run2.log   || { echo "FAIL: ckpt_dump() did not return 1 on restore"; fail=1; }
grep -q "read '67890'" run2.log         || { echo "FAIL: input fd not restored at offset 5"; fail=1; }
[ ! -e output.txt ]                     || { echo "FAIL: output.txt recreated (writes not sinkholed)"; fail=1; }
[ $fail -eq 0 ] && echo "PASS: test_fd"
exit $fail
