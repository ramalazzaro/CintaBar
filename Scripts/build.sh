#!/bin/bash
# Builds CintaBar and assembles a sandboxed, ad hoc signed app bundle.
#
#   Scripts/build.sh            Build into build/CintaBar.app
#   Scripts/build.sh --install  Also copy it to /Applications and launch it
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity to use instead of an ad hoc signature
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal, so one build runs on Apple silicon and Intel Macs.
swift build --configuration release --arch arm64 --arch x86_64

app=build/CintaBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build --configuration release --arch arm64 --arch x86_64 --show-bin-path)/CintaBar" "$app/Contents/MacOS/CintaBar"
cp Support/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# An ad hoc signature is enough to run locally with the sandbox and the hardened runtime on, but
# macOS then asks for Bluetooth permission again after every rebuild. Set CODESIGN_IDENTITY to a
# certificate of your own to avoid that.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --options runtime \
    --entitlements Support/CintaBar.entitlements "$app"
echo "Built $app"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x CintaBar || true
    rm -rf /Applications/CintaBar.app
    cp -R "$app" /Applications/CintaBar.app
    open /Applications/CintaBar.app
    echo "Installed /Applications/CintaBar.app"
fi
