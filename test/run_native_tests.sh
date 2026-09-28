#!/bin/bash
# run_native_tests.sh - Regression tests of the checkpoint/restore flow that
# run on the host (loader --native), without gem5.
#
#   test/run_native_tests.sh [N]      # N = repetitions of the random tests (default 10)
#
# Checkpoints are generated with launch_scripts/gen_ckpt.sh, the same single
# path used for SPEC and for the gem5 end-to-end test (launch_scripts/e2e_altek.sh).
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
# What these CANNOT check (gem5-only behaviour) is covered by
# launch_scripts/e2e_altek.sh and docs/VERIFICACION_GEM5.md.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
GEN="$REPO/launch_scripts/gen_ckpt.sh"
N="${1:-10}"

make -C "$REPO" >/dev/null || { echo "build failed"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
CFL="-O2 -mno-avx -mno-avx2"
gcc $CFL -fPIE -pie -o test_redzone       "$HERE/test_redzone.c"
gcc $CFL -fPIE -pie -o test_signal_malloc "$HERE/test_signal_malloc.c"
gcc -O1 -mno-avx -fPIE -pie -o test_vdso  "$HERE/test_vdso.c"

pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
ko()  { echo "  FAIL  $*"; fail=$((fail+1)); }

gen() { "$GEN" "$@" > /dev/null 2> gen.err || { cat gen.err; return 1; }; }
restore() {    # restore <loader> <ckpt> [args]: program stdout
    local ld=$1 ck=$2; shift 2
    timeout 60 setarch -R "$REPO/build/$ld" "$ck" --native "$@" 2> "$ck.restore.log"
}

echo "=== target_app (static, ckpt_dump) ==="
gen -w -o t.ckpt -- "$REPO/build/target_app" "$WORK/t.ckpt"
ref=$(grep -o 'checksum=0x[0-9a-f]*' t.ckpt.log | tail -1)
grep -q "fpregs_size = 512" t.ckpt.inspect && ok "fpregs_size saved" || ko "fpregs_size not 512"
restore loader t.ckpt > /dev/null
got=$(grep -o 'checksum=0x[0-9a-f]*' t.ckpt.restore.log)
[ -n "$ref" ] && [ "$ref" = "$got" ] && ok "restored checksum matches ($ref)" || ko "checksum '$got' != '$ref'"

echo "=== test_fd ==="
"$HERE/run_test.sh" > fd.log 2>&1 && ok "test_fd" || { ko "test_fd"; tail -5 fd.log; }

echo "=== red zone ($N runs) ==="
for i in $(seq 1 "$N"); do
    gen -t $((150000000 + i * 37000000)) -o rz.ckpt -- ./test_redzone || { ko "redzone run $i: no checkpoint"; continue; }
    out=$(restore loader_pie rz.ckpt)
    if [[ "$out" == *"REDZONE OK"* && "$out" != *CORRUPT* ]]; then ok "redzone run $i"
    else ko "redzone run $i: '$(echo "$out" | tail -1)'"; fi
done

echo "=== signal inside malloc ($N runs) ==="
for i in $(seq 1 "$N"); do
    # gen_ckpt fails (timeout) if the dump deadlocks inside malloc
    gen --timeout 20 -t $(( (RANDOM % 700 + 50) * 1000000 )) -o m.ckpt -- ./test_signal_malloc \
        || { ko "malloc run $i: no checkpoint (deadlock?)"; continue; }
    out=$(restore loader_pie m.ckpt)
    [[ "$out" == *"MALLOC OK"* ]] && ok "malloc run $i" || ko "malloc run $i: '$(echo "$out" | tail -1)'"
done

echo "=== vdso ==="
gen -t 300000000 -o v.ckpt -- ./test_vdso || ko "vdso: no checkpoint"
out=$(restore loader_pie v.ckpt)
[[ "$out" == *"CLOCK OK"* ]] && ok "vdso clock" || ko "vdso clock: '$(echo "$out" | tail -1)'"

echo "=== static non-PIE malloc after restore ==="
# Its heap lies below the loader's break. Linux only lets the loader move the
# break down with prctl(PR_SET_MM), which needs CAP_SYS_RESOURCE (gem5 does it
# with brk(), see docs/VERIFICACION_GEM5.md). Without the capability the same
# program is linked above the loader, which exercises the brk-grow path.
SFLAGS="-O2 -static -no-pie -fno-stack-protector"
if [ $(( 0x$(awk '/CapEff/{print $2}' /proc/self/status) >> 24 & 1 )) -eq 1 ]; then
    extra=""; what="heap below the loader (prctl)"
else
    extra="-Wl,-Ttext-segment=0x40000000"; what="heap above the loader (no CAP_SYS_RESOURCE)"
fi
gcc $SFLAGS $extra -o test_static_malloc "$HERE/test_static_malloc.c" \
    "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"
gen -w -o sm.ckpt -- ./test_static_malloc "$WORK/sm.ckpt"
out=$(restore loader sm.ckpt)
[ "$out" = "STATIC MALLOC OK" ] && ok "static malloc, $what" || ko "static malloc, $what: '$out'"

echo "=== native loader must not execute m5_exit ==="
restore loader t.ckpt > /dev/null; rc=$?
[ "$rc" = 0 ] && ok "--native skips m5_exit" || ko "loader --native exit code $rc"

echo ""
echo "RESULT: $pass passed, $fail failed"
[ $fail -eq 0 ]
