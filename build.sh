#!/bin/bash
# Build PeaceMenu.app, sign it and install it in ~/Applications.
# A stable signing identity keeps the Accessibility permission across rebuilds.
#
# VERSION=1.2.0 ./build.sh  sets the version shown in the app; without it, the latest git tag
#                           (v1.2.0 gives 1.2.0), else the version in Info.plist.
# UNIVERSAL=1               builds for both Apple silicon and Intel Macs, as releases do.
# NO_INSTALL=1              builds build/PeaceMenu.app only (the Release workflow).
# SIGN_KEYCHAIN=<path>      the keychain holding SIGN_ID, when it isn't the login one.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

# SIGN_ID, else the "PeaceMenu Release Signing" certificate (the one releases use, so the
# Accessibility permission is the same for local builds and releases), else the first
# "Apple Development" identity, else ad hoc (granting Accessibility again after each rebuild).
# The release certificate is self-signed, hence not "valid" for find-identity -v.
SIGN_ID="${SIGN_ID:-$(security find-identity -p codesigning | awk '/"PeaceMenu Release Signing"/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
SIGN_ID="${SIGN_ID:--}"
APP="build/PeaceMenu.app"
DEST="$HOME/Applications/PeaceMenu.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
compile() { # compile <output> [target]
	swiftc -O -swift-version 5 ${2:+-target "$2"} -o "$1" Sources/*.swift \
		-framework AppKit -framework SwiftUI -framework ApplicationServices -framework ServiceManagement
}
if [[ -n "${UNIVERSAL:-}" ]]; then
	MIN=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Info.plist)
	compile build/PeaceMenu-arm64 "arm64-apple-macos$MIN"
	compile build/PeaceMenu-x86_64 "x86_64-apple-macos$MIN"
	lipo -create -output "$APP/Contents/MacOS/PeaceMenu" build/PeaceMenu-arm64 build/PeaceMenu-x86_64
	rm -f build/PeaceMenu-arm64 build/PeaceMenu-x86_64
else
	compile "$APP/Contents/MacOS/PeaceMenu"
fi
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_ID" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$APP"
echo "Built $APP $VERSION ($BUILD)"
[[ -n "${NO_INSTALL:-}" ]] && exit 0

pkill -x PeaceMenu || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
