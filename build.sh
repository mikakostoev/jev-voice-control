#!/bin/bash
# Builds Jev.app (the bundle is needed so macOS shows the mic/speech permission prompts).
set -euo pipefail
cd "$(dirname "$0")"
# Xcode license not accepted yet? The standalone Command Line Tools build this just as well.
xcrun --show-sdk-path >/dev/null 2>&1 || export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swift build -c release
APP=Jev.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Jev "$APP/Contents/MacOS/Jev"
cp Info.plist "$APP/Contents/"
cp .env "$APP/Contents/Resources/.env"
cp defaults.json "$APP/Contents/Resources/defaults.json"
# With a self-signed "Jev Dev" certificate in the keychain the signature stays stable across builds,
# so macOS keeps the Accessibility grant. Without it: ad-hoc signature, re-grant after every build.
if security find-identity -p codesigning | grep -q '"Jev Dev"'; then SIGN="Jev Dev"; else SIGN=-; fi
codesign --force --sign "$SIGN" "$APP"
# Install where Spotlight and `open -a Jev` can find it from any directory.
mkdir -p "$HOME/Applications"
pkill -x Jev || true  # a running copy would keep executing the old binary
rm -rf "$HOME/Applications/$APP"
mv "$APP" "$HOME/Applications/$APP"  # a second copy would make `open -a Jev` ambiguous
open "$HOME/Applications/$APP"
echo "Built, installed and relaunched ~/Applications/$APP"
