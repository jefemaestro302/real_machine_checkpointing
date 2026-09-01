# _common.sh - Rutas compartidas por los lanzadores. Se resuelve todo a partir
# de la ubicacion del propio script, para que el repo sea la unica fuente de
# verdad y no haya copias sueltas divergiendo en el cluster.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GEM5_BIN="${GEM5_BIN:-$HOME/gap_gem5/gem5/build/X86/gem5.opt}"
LOADER="${LOADER:-$REPO/build/loader}"
LIBCKPT="${LIBCKPT:-$REPO/build/libckpt.so}"
CKPT_DIR="${CKPT_DIR:-$HOME/checkpoints}"
OUT_BASE="${OUT_BASE:-$HOME/TFM/m5out}"

die() { echo "ERROR: $*" >&2; exit 1; }

check_built() {
    [ -x "$LOADER" ]  || die "no existe $LOADER  (ejecuta: make -C $REPO)"
}
