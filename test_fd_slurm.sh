#!/bin/bash
#SBATCH --job-name=test_fd_gem5
#SBATCH --output=slurm_test_fd.out
#SBATCH --error=slurm_test_fd.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:30:00
#
# Prueba de FDs en gem5: vuelca test_fd en nativo, mueve su fichero de
# entrada y lo restaura en gem5 con un remapeo OLD=NEW. Ver
# docs/VERIFICACION_GEM5.md (prueba "FDs").
#
#   sbatch test_fd_slurm.sh      (desde la raiz del repo)
set -euo pipefail
REPO="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$REPO/launch_scripts/_common.sh"
check_built

WORK="${WORK:-$HOME/TFM/test_fd_gem5}"
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"

echo "=== Compilando test_fd ==="
gcc -O2 -g -Wall -fno-stack-protector -fno-builtin -static -no-pie \
    -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 \
    -o test_fd "$REPO/test/test_fd.c" "$REPO/src/dumper.c" "$REPO/src/dumper_asm.S"

printf 1234567890 > input1.txt

echo "=== Volcado nativo ==="
NORAND="setarch -R"; $NORAND true 2>/dev/null || NORAND=""
$NORAND ./test_fd "$WORK/input1.txt" "$WORK/output.txt"

mkdir -p new_dir
mv input1.txt new_dir/input1.txt
rm -f output.txt

echo "=== Restauracion en gem5 ==="
LOADER_OPTS="$WORK/input1.txt=$WORK/new_dir/input1.txt" \
OUT_BASE="$WORK" \
    "$REPO/launch_scripts/run_st_timing.sh" "$WORK/dump.ckpt" 100000000 timing | tee gem5.log

echo "=== Comprobaciones ==="
fail=0
grep -q "Restored from dump" gem5.log "$WORK"/*/simout 2>/dev/null || { echo "FALLO: no aparece 'Restored from dump'"; fail=1; }
grep -q "read '67890'" gem5.log "$WORK"/*/simout 2>/dev/null     || { echo "FALLO: el fd de entrada no se restauro en el offset 5"; fail=1; }
[ ! -e output.txt ] || { echo "FALLO: output.txt se ha recreado (escrituras no sumideradas)"; fail=1; }
[ $fail -eq 0 ] && echo "OK: prueba de FDs en gem5"
exit $fail
