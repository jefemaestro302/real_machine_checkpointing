#!/bin/bash

# Directories
TFM_DIR="$HOME/TFM"
APPS_DIR="$TFM_DIR/repositories/ia_apps/3_bin"
ST_CKPT_DIR="$TFM_DIR/checkpoints/ia_apps/ST"

echo "==========================================="
echo "   Generating ST Checkpoints for ia_apps   "
echo "   (NUEVA VERSIÓN ESTÁTICA MUSL)           "
echo "==========================================="

# NOTA IMPORTANTE: Para que este script funcione, los binarios en $APPS_DIR
# DEBEN haber sido compilados estáticamente en el contenedor Alpine (musl)
# y enlazados con libckpt_static.o. Ya NO usamos libckpt.so ni LD_PRELOAD.

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

    echo "▶ Tomando checkpoint de: $APP_NAME"
    
    # Clean previous checkpoint if it exists
    rm -f "$CKPT_FILE"

    # Ejecutamos la aplicación. El binario estático ya contiene la lógica de checkpoint.
    CKPT_AFTER_NS=5000000 CKPT_OUTPUT="$CKPT_FILE" "$BIN_PATH"
    
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
