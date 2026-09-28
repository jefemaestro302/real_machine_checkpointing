#!/bin/bash
# run_native_tests.sh - Regression tests of the checkpoint/restore flow that
# run on the host (loader --native), without gem5.
#
#   test/run_native_tests.sh [N]      # N = repetitions of the random tests (default 10)
#
# Each test targets a bug that used to break the flow:
#   target_app  static non-PIE app with ckpt_dump(): fpregs_size/rax restored
#   test_fd     FD restore, remapping OLD=NEW, sinkholed writes
#   redzone     loader must not write below the restored %rsp (red zone)
#   malloc      dump from a signal that lands inside malloc (no deadlock),
#               and restored malloc keeps working (program break moved)
#   vdso        clock_gettime/gettimeofday keep working after restore
#   static      static non-PIE program that grows/trims its heap after restore
#
# What these CANNOT check (gem5-only behaviour) is covered in
# docs/VERIFICACION_GEM5.md.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
N="${1:-10}"
NORAND="setarch -R"
$NORAND true 2>/dev/null || { echo "WARNING: setarch -R unavailable, running with ASLR"; NORAND=""; }

make -C "$REPO" >/dev/null || { echo "build failed"; exit 1; }
LIB="$REPO/build/libckpt.so"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
gcc -O2 -o test_redzone       "$HERE/test_redzone.c"
gcc -O2 -o test_signal_malloc "$HERE/test_signal_malloc.c"
gcc -O1 -o test_vdso          "$HERE/test_vdso.c"

pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
ko()  { echo "  FAIL  $*"; fail=$((fail+1)); }

# Dump a dynamically linked (PIE) program with libckpt.so after $2 ns.
# setarch must wrap env: libckpt.so drops LD_PRELOAD from the environment of
# the process it is loaded into, so `env LD_PRELOAD=... setarch -R prog`
# would checkpoint setarch's child without the library.
dump_dyn() {   # dump_dyn <prog> <ns> <out>
    rm -f "$3"
    timeout 30 $NORAND env LD_PRELOAD="$LIB" CKPT_AFTER_NS="$2" CKPT_OUTPUT="$3" \
        "./$1" > /dev/null 2> "$3.log"
}
restore() {    # restore <loader> <ckpt> [args]
    local ld=$1 ck=$2; shift 2
    timeout 30 $NORAND "$REPO/build/$ld" "$ck" --native "$@" 2> "$ck.restore.log"
}

echo "=== target_app (static, ckpt_dump) ==="
rm -f t.ckpt
$NORAND "$REPO/build/target_app" t.ckpt > /dev/null 2> t.log
ref=$(grep -o 'checksum=0x[0-9a-f]*' t.log)
python3 "$REPO/tools/ckpt_inspect.py" t.ckpt > t.inspect
grep -q "fpregs_size = 512" t.inspect && ok "fpregs_size saved" || ko "fpregs_size not 512"
restore loader t.ckpt > /dev/null
got=$(grep -o 'checksum=0x[0-9a-f]*' t.ckpt.restore.log)
[ -n "$ref" ] && [ "$ref" = "$got" ] && ok "restored checksum matches ($ref)" || ko "checksum '$got' != '$ref'"

echo "=== test_fd ==="
"$HERE/run_test.sh" > fd.log 2>&1 && ok "test_fd" || { ko "test_fd"; tail -5 fd.log; }

echo "=== red zone ($N runs) ==="
for i in $(seq 1 "$N"); do
    dump_dyn test_redzone $((150000000 + i * 37000000)) rz.ckpt
    out=$(restore loader_pie rz.ckpt)
    [ "$out" = "REDZONE OK" ] && ok "redzone run $i" || ko "redzone run $i: '$out'"
done

echo "=== signal inside malloc ($N runs) ==="
for i in $(seq 1 "$N"); do
    dump_dyn test_signal_malloc $(( (RANDOM % 900 + 50) * 1000000 )) m.ckpt
    rc=$?
    if [ $rc -eq 124 ]; then ko "malloc run $i: dump deadlocked"; continue; fi
    [ -f m.ckpt ] || { ko "malloc run $i: no checkpoint"; continue; }
    out=$(restore loader_pie m.ckpt)
    [ "$out" = "MALLOC OK" ] && ok "malloc run $i" || ko "malloc run $i: '$out'"
done

echo "=== vdso ==="
dump_dyn test_vdso 300000000 v.ckpt
out=$(restore loader_pie v.ckpt)
[ "$out" = "CLOCK OK" ] && ok "vdso clock" || ko "vdso clock: '$out'"

echo "=== static non-PIE malloc after restore ==="
# Its heap lies below the loader's break. Linux only lets the loader move the
# break down with prctl(PR_SET_MM), which needs CAP_SYS_RESOURCE (gem5 does it
# with brk(), see docs/VERIFICACION_GEM5.md). Without the capability the same
# program is linked above the loader, which exercises the brk-grow path.
SFLAGS="-O2 -static -no-pie -fno-stack-protector"
if [ $(( 0x$(awk '/CapEff/{print $2}' /proc/self/status) >> 24 & 1 )) -eq 1 ]; then
    gcc $SFLAGS -o test_static_malloc "$HERE/test_static_malloc.c" \
        "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"
    what="heap below the loader (prctl)"
else
    gcc $SFLAGS -Wl,-Ttext-segment=0x40000000 -o test_static_malloc "$HERE/test_static_malloc.c" \
        "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"
    what="heap above the loader (no CAP_SYS_RESOURCE)"
fi
rm -f sm.ckpt
$NORAND ./test_static_malloc sm.ckpt > /dev/null 2>&1
out=$(restore loader sm.ckpt)
[ "$out" = "STATIC MALLOC OK" ] && ok "static malloc, $what" || ko "static malloc, $what: '$out'"

echo "=== native loader must not execute m5_exit ==="
out=$(restore loader t.ckpt >/dev/null; echo $?)
[ "$out" = 0 ] && ok "--native skips m5_exit" || ko "loader --native exit code $out"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ $fail -eq 0 ]
