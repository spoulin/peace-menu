#!/bin/bash
# Build PeaceMenu.app, sign it and install it in ~/Applications.
# A stable signing identity keeps the Accessibility permission across rebuilds.
#
# VERSION=1.2.0 ./build.sh  sets the version shown in the app (default: Info.plist).
# NO_INSTALL=1              builds build/PeaceMenu.app only.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# SIGN_ID, else the first "Apple Development" identity, else ad hoc
# (ad hoc means granting Accessibility again after each rebuild).
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
APP="build/PeaceMenu.app"
DEST="$HOME/Applications/PeaceMenu.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/PeaceMenu" Sources/*.swift \
	-framework AppKit -framework SwiftUI -framework ApplicationServices -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" "$APP"
echo "Built $APP $VERSION ($BUILD)"
[[ -n "${NO_INSTALL:-}" ]] && exit 0

pkill -x PeaceMenu || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
