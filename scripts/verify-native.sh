#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$(mktemp -d)/NativeChecks.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
cat > "$app/Info.plist" <<'PLIST'
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>studio.foco.nativechecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>NativeChecks</string>
</dict></plist>
PLIST
python3 scripts/fetch-model.py
xcrun coremlcompiler compile Foco/DepthBase.mlpackage "$app/Resources"
if ! xcrun --sdk macosx metal --version; then xcodebuild -downloadComponent MetalToolchain; fi
PLATFORM_NAME=macosx DERIVED_FILE_DIR="$app" SCRIPT_INPUT_FILE_0="$PWD/Foco/Lab.ci.metal" \
  SCRIPT_OUTPUT_FILE_0="$app/Resources/FocoLab.metallib" sh scripts/compile-kernels.sh
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  Foco/OriginalJPEG.swift Foco/DepthBase.swift Foco/Laboratory.swift scripts/NativeChecks.swift -o "$app/MacOS/NativeChecks"
"$app/MacOS/NativeChecks"

