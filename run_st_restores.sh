#!/bin/bash
#SBATCH --job-name=gem5_ia_st_restore
#SBATCH --output=/dev/null
#SBATCH --error=/dev/null
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=12:00:00
#SBATCH --array=0-16%10

# SLURM script to restore all ST checkpoints
TFM_DIR="$HOME/TFM"
CKPT_DIR="$TFM_DIR/checkpoints/ia_apps/ST"
RESULTS_DIR="$TFM_DIR/results/ia_apps/ST"
GEM5_BIN="$HOME/gap_gem5/gem5/build/X86/gem5.opt"
CFG_SCRIPT="$TFM_DIR/gem5_scripts/X86/x86_st.py"
LOADER="$TFM_DIR/repositories/real_machine_checkpoint/build/loader"

mkdir -p "$RESULTS_DIR"

MANIFEST_FILE="${RESULTS_DIR}/st_manifest.txt"

# Only create the manifest on the first array task (or before submitting)
# But since this is submitted via sbatch, it's safer to create it if it doesn't exist.
# However, race conditions might occur if all tasks try to create it at the same time.
# A simple solution is to create the manifest before submitting, OR lock it.
if [ "$SLURM_ARRAY_TASK_ID" == "0" ] || [ ! -f "$MANIFEST_FILE" ]; then
    find "$CKPT_DIR" -name "dump.ckpt" | sort > "$MANIFEST_FILE.tmp"
    mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
fi

CKPT_PATH=$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$MANIFEST_FILE")

if [ -z "$CKPT_PATH" ]; then
    echo "No checkpoint found for array index $SLURM_ARRAY_TASK_ID"
    exit 0
fi

APP_NAME=$(basename $(dirname "$CKPT_PATH"))
OUT_DIR="$RESULTS_DIR/$APP_NAME"
mkdir -p "$OUT_DIR"

out_log="${OUT_DIR}/slurm_${APP_NAME}.out"
err_log="${OUT_DIR}/slurm_${APP_NAME}.err"
exec >"$out_log" 2>"$err_log"

export GLIBC_TUNABLES="glibc.cpu.hwcaps=-SSE4_2,-SSE4_1,-SSSE3,-AVX,-AVX2,-AVX512F"

echo "========================================================="
echo " Node: $SLURM_NODENAME"
echo " App: $APP_NAME"
echo " Checkpoint: $CKPT_PATH"
echo "========================================================="

cd "$OUT_DIR"

"$GEM5_BIN" --outdir="$OUT_DIR" "$CFG_SCRIPT" \
    --cmd="$LOADER" \
    --options="$CKPT_PATH" \
    --maxinsts=100000000 \
    --pmudispatch --pmuissue

echo "✅ Restoration completed for $APP_NAME"
echo "========================================================="
