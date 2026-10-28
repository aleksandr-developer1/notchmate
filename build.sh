#!/bin/zsh
# Builds NotchMate.app (release) and optionally installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="build/NotchMate.app"
ADAPTER="Vendor/mediaremote-adapter"

# Stable signing identity: macOS ties Accessibility / Automation / Keychain permissions to it,
# so they survive rebuilds. Ad-hoc signatures change on every build and silently lose permissions.
# Override with SIGN_ID=<sha1 or name>; SIGN_ID=- forces ad-hoc.
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
  SIGN_ID=${SIGN_ID:--}
fi
# Notarization needs a Developer ID certificate and Hardened Runtime. Other identities sign as before.
# NOTARIZE=1 NOTARY_PROFILE=<name from `xcrun notarytool store-credentials`> ./build.sh
SIGN_NAME=$([[ "$SIGN_ID" == "-" ]] && echo ad-hoc || security find-identity -v -p codesigning | grep "$SIGN_ID" | sed 's/.*"\(.*\)"/\1/')
RUNTIME=()
if [[ "${NOTARIZE:-0}" == "1" ]]; then
  [[ "$SIGN_NAME" == Developer\ ID\ Application* ]] || { echo "✗ NOTARIZE=1 needs a Developer ID Application certificate (got: $SIGN_NAME)"; exit 1; }
  [[ -n "${NOTARY_PROFILE:-}" ]] || { echo "✗ NOTARIZE=1 needs NOTARY_PROFILE (xcrun notarytool store-credentials)"; exit 1; }
  RUNTIME=(--options runtime --timestamp --entitlements Resources/NotchMate.entitlements)
fi

# 0. Vendored adapter is a git submodule — fetch it on a fresh clone
if [[ ! -f "$ADAPTER/include/MediaRemoteAdapter.h" ]]; then
  echo "▸ Fetching $ADAPTER (git submodule)"
  git submodule update --init --recursive
fi

# 1. MediaRemote adapter framework (no cmake needed)
if [[ ! -f "$ADAPTER/build/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" ]]; then
  echo "▸ Building MediaRemoteAdapter.framework"
  FW="$ADAPTER/build/MediaRemoteAdapter.framework"
  mkdir -p "$FW/Versions/A/Resources" "$FW/Versions/A/Headers"
  clang -dynamiclib -arch arm64 -arch x86_64 -fobjc-arc -fvisibility=default -I"$ADAPTER/include" -I"$ADAPTER/src" \
    "$ADAPTER"/src/adapter/*.m "$ADAPTER/src/private/MediaRemote.m" "$ADAPTER"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FW/Versions/A/MediaRemoteAdapter" 2>/dev/null
  cp "$ADAPTER/include/MediaRemoteAdapter.h" "$FW/Versions/A/Headers/"
  cp Resources/MediaRemoteAdapter-Info.plist "$FW/Versions/A/Resources/Info.plist"
  (cd "$FW/Versions" && ln -sfn A Current)
  (cd "$FW" && ln -sfn Versions/Current/MediaRemoteAdapter MediaRemoteAdapter && ln -sfn Versions/Current/Resources Resources && ln -sfn Versions/Current/Headers Headers)
fi

# 2. Swift
echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/NotchMate"

# 3. Bundle
echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchMate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Translations. Russian is the source language (the keys are Russian text), so it gets an empty table.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources"
xcrun xcstringstool compile Resources/InfoPlist.xcstrings --output-directory "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/ru.lproj"
echo "/* Source language: the keys already are the Russian text. */" > "$APP/Contents/Resources/ru.lproj/Localizable.strings"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$ADAPTER/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp Resources/garmin_sync.py "$APP/Contents/Resources/"
cp -R "$ADAPTER/build/MediaRemoteAdapter.framework" "$APP/Contents/Resources/"

# The adapter framework is loaded by /usr/bin/perl, not by the app; it only needs a runtime signature for notarization.
FW_SIGN=(-)
[[ ${#RUNTIME[@]} -gt 0 ]] && FW_SIGN=("$SIGN_ID" --options runtime --timestamp)
codesign --force --deep --sign "${FW_SIGN[@]}" "$APP/Contents/Resources/MediaRemoteAdapter.framework" >/dev/null
codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$APP/Contents/MacOS/NotchMate" >/dev/null
codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$APP" >/dev/null
echo "▸ Signed with: $SIGN_NAME"

if [[ ${#RUNTIME[@]} -gt 0 ]]; then
  echo "▸ Notarizing"
  ZIP="build/NotchMate-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  echo "▸ Notarized and stapled"
fi
echo "✓ Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST=/Applications/NotchMate.app
  pkill -x NotchMate 2>/dev/null || true
  pkill -x Shtorka 2>/dev/null || true   # the app's former name
  sleep 0.5
  rm -rf "$DEST"
  cp -R "$APP" /Applications/
  # Old per-user install location — keep only one copy so permissions and hooks point to one app.
  for old in ~/Applications/NotchMate.app /Applications/Shtorka.app ~/Applications/Shtorka.app; do
    if [[ -d "$old" ]]; then mv "$old" ~/.Trash/"$(basename "$old" .app)-old-$(date +%s).app"; fi
  done
  open "$DEST"
  echo "✓ Installed to $DEST and launched"
fi
