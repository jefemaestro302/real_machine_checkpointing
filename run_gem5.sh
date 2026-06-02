#!/bin/bash
# run_gem5.sh — Run a checkpoint in gem5 SE mode
#
# Usage:
#   ./run_gem5.sh [checkpoint.ckpt] [--cpu atomic|o3] [--mem 8GB]
#
# Defaults: tailbench_dump.ckpt, atomic CPU, 8GB memory
#
# Examples:
#   ./run_gem5.sh                                    # quick validation
#   ./run_gem5.sh tailbench_dump.ckpt --cpu o3       # full OoO simulation
#   ./run_gem5.sh my_roi.ckpt --cpu o3 --mem 16GB

set -e

# ── Defaults ───────────────────────────────────────────────────────────────
CKPT="${1:-tailbench_dump.ckpt}"
CPU="atomic"
MEM="8GB"
GEM5_ROOT="${GEM5_ROOT:-../../../gem5}"

# ── Parse args ─────────────────────────────────────────────────────────────
shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu)   CPU="$2";  shift 2 ;;
        --mem)   MEM="$2";  shift 2 ;;
        --gem5)  GEM5_ROOT="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── CPU type mapping ───────────────────────────────────────────────────────
case "$CPU" in
    atomic|Atomic)  CPU_TYPE="AtomicSimpleCPU"; CACHE_FLAGS="" ;;
    o3|O3)          CPU_TYPE="O3CPU";           CACHE_FLAGS="--caches" ;;
    minor|Minor)    CPU_TYPE="MinorCPU";        CACHE_FLAGS="--caches" ;;
    *) echo "Unknown CPU type: $CPU (use atomic, o3, or minor)"; exit 1 ;;
esac

# ── Validate paths ─────────────────────────────────────────────────────────
GEM5_BIN="$GEM5_ROOT/build/X86/gem5.opt"
GEM5_CFG="$GEM5_ROOT/configs/deprecated/example/se.py"
LOADER="$(dirname "$0")/build/loader"

if [[ ! -f "$GEM5_BIN" ]]; then
    echo "ERROR: gem5 binary not found at $GEM5_BIN"
    echo "       Set GEM5_ROOT env var or use --gem5 /path/to/gem5"
    exit 1
fi
if [[ ! -f "$CKPT" ]]; then
    echo "ERROR: checkpoint file not found: $CKPT"
    exit 1
fi
if [[ ! -f "$LOADER" ]]; then
    echo "ERROR: loader binary not found at $LOADER (run 'make' first)"
    exit 1
fi

# ── GLIBC_TUNABLES: disable SSE4.1/4.2/SSSE3/AVX so glibc uses SSE2 paths ─
# This prevents gem5 from hitting unimplemented SSE4.1 instructions
# (e.g. ptest_Vdq_Wdq) that glibc's ifunc resolver may have selected.
# NOTE: for a proper restore these should match what was set at checkpoint time.
export GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"

# ── Run ────────────────────────────────────────────────────────────────────
echo "========================================================"
echo "  gem5 SE Checkpoint Restore"
echo "========================================================"
echo "  Checkpoint : $CKPT  ($(du -h "$CKPT" | cut -f1))"
echo "  CPU model  : $CPU_TYPE"
echo "  Memory     : $MEM"
echo "  gem5       : $GEM5_BIN"
echo "  Output     : m5out/stats.txt"
echo "========================================================"

"$GEM5_BIN" "$GEM5_CFG" \
    --mem-size="$MEM" \
    --cpu-type="$CPU_TYPE" \
    $CACHE_FLAGS \
    -c "$LOADER" \
    -o "$CKPT"

echo ""
echo "========================================================"
echo "  Done — results in m5out/stats.txt"
echo "========================================================"
echo ""
echo "Key stats:"
grep -E "simSeconds|simInsts|system.cpu.cpi|system.cpu.ipc|system.cpu.dcache.overall_miss_rate|system.cpu.icache.overall_miss_rate" \
    m5out/stats.txt 2>/dev/null | head -10 || echo "(run completed, check m5out/stats.txt)"
