#!/bin/sh
set -eu
mkdir -p "$(dirname "$SCRIPT_OUTPUT_FILE_0")"
xcrun --sdk "$PLATFORM_NAME" metal -c -fcikernel "$SCRIPT_INPUT_FILE_0" -o "$DERIVED_FILE_DIR/FocoLab.air"
xcrun --sdk "$PLATFORM_NAME" metallib -cikernel "$DERIVED_FILE_DIR/FocoLab.air" -o "$SCRIPT_OUTPUT_FILE_0"
