# _common.sh - Rutas compartidas por los lanzadores. Se resuelve todo a partir
# de la ubicacion del propio script, para que el repo sea la unica fuente de
# verdad y no haya copias sueltas divergiendo en el cluster.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GEM5_BIN="${GEM5_BIN:-$HOME/gap_gem5/gem5/build/X86/gem5.opt}"
# LOADER restaura checkpoints no PIE; LOADER_PIE los PIE (SPEC, la mayoria de
# apps dinamicas). Las configs de gem5 eligen entre ambos segun el checkpoint.
LOADER="${LOADER:-$REPO/build/loader}"
LOADER_PIE="${LOADER_PIE:-$REPO/build/loader_pie}"
LIBCKPT="${LIBCKPT:-$REPO/build/libckpt.so}"
CKPT_DIR="${CKPT_DIR:-$HOME/checkpoints}"
OUT_BASE="${OUT_BASE:-$HOME/TFM/m5out}"

# Entorno de generacion (lo aplica launch_scripts/gen_ckpt.sh, y solo el):
# la glibc elige en el arranque (IFUNC) las variantes de memcpy, strlen...
# segun la CPU; estas capacidades se ocultan para que elija las rutas SSE2,
# que gem5 SE si implementa.
RMC_NOAVX_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F,-AVX_Usable,-AVX2_Usable,-AVX512F_Usable,-AVX_Fast_Unaligned_Load"

die() { echo "ERROR: $*" >&2; exit 1; }

check_built() {
    [ -x "$LOADER" ]     || die "no existe $LOADER  (ejecuta: make -C $REPO)"
    [ -x "$LOADER_PIE" ] || die "no existe $LOADER_PIE  (ejecuta: make -C $REPO)"
}
