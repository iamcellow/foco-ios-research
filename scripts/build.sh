#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/fetch-model.py
xcodebuild -project Foco.xcodeproj -scheme Foco -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
mkdir -p build/Payload
ditto build/DerivedData/Build/Products/Release-iphoneos/Foco.app build/Payload/Foco.app
cp LICENCA-MODELO.txt build/Payload/Foco.app/
echo 'Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.' > build/Payload/Foco.app/Attribution.txt
test -s build/Payload/Foco.app/FocoLab.metallib
test -d build/Payload/Foco.app/DepthBase.mlmodelc
(cd build && /usr/bin/ditto -c -k --keepParent Payload Foco-sem-assinatura.ipa)
