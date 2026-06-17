#!/bin/bash

# Directories
TFM_DIR="$HOME/TFM"
APPS_DIR="$TFM_DIR/repositories/ia_apps/3_bin"
CKPT_TOOL="$TFM_DIR/repositories/real_machine_checkpoint/build/libckpt.so"
ST_CKPT_DIR="$TFM_DIR/checkpoints/ia_apps/ST"

echo "==========================================="
echo "   Generating ST Checkpoints for ia_apps   "
echo "==========================================="

if [ ! -f "$CKPT_TOOL" ]; then
    echo "❌ Error: libckpt.so no se encuentra en $CKPT_TOOL"
    echo "Asegúrate de haber compilado el dumper en el remoto."
    exit 1
fi

mkdir -p "$ST_CKPT_DIR"

# Iterate over all Single-Threaded binaries
shopt -s nullglob
for BIN_PATH in "$APPS_DIR"/*_native_thd1.out; do
    if [ ! -f "$BIN_PATH" ]; then
        echo "❌ No se encontraron binarios ST en $APPS_DIR"
        break
    fi

    BASENAME=$(basename "$BIN_PATH")
    APP_NAME="${BASENAME%_native_thd1.out}"

    APP_CKPT_DIR="$ST_CKPT_DIR/$APP_NAME"
    mkdir -p "$APP_CKPT_DIR"

    CKPT_FILE="$APP_CKPT_DIR/dump.ckpt"

    echo "▶️ Tomando checkpoint de: $APP_NAME"
    
    # Clean previous checkpoint if it exists
    rm -f "$CKPT_FILE"

    # Execute the app with LD_PRELOAD injected
    # Use CKPT_AFTER_NS=5000000 (5ms) to trigger it.
    CKPT_AFTER_NS=5000000 LD_PRELOAD="$CKPT_TOOL" CKPT_OUTPUT="$CKPT_FILE" "$BIN_PATH"
    
    if [ -f "$CKPT_FILE" ]; then
        echo "✅ Checkpoint exitoso para $APP_NAME: $(du -sh "$CKPT_FILE" | awk '{print $1}')"
    else
        echo "❌ Fallo al generar el checkpoint para $APP_NAME"
    fi
    echo "-------------------------------------------"
done

echo "==========================================="
echo "🎉 Proceso de Checkpoint ST Finalizado!"
echo "==========================================="
