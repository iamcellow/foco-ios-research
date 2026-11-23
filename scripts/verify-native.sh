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
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx15.0" \
  Foco/OriginalJPEG.swift Foco/DepthBase.swift scripts/NativeChecks.swift -o "$app/MacOS/NativeChecks"
"$app/MacOS/NativeChecks"

