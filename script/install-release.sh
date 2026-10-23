#!/bin/bash
# Builds the optimised Release version of UnifiedTools and installs it to ~/Applications.
# Use this for everyday running; the Debug build Xcode produces is several times slower and heavier.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="${TMPDIR:-/tmp}/UnifiedTools-release-build"
target="$HOME/Applications/UnifiedTools.app"

xcodebuild \
    -project "$root/app/UnifiedTools.xcodeproj" \
    -scheme UnifiedTools \
    -configuration Release \
    -derivedDataPath "$derived" \
    build

pkill -x UnifiedTools 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$target"
cp -R "$derived/Build/Products/Release/UnifiedTools.app" "$target"
open "$target"
echo "Installed to $target"
