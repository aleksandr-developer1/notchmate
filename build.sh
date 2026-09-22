#!/bin/zsh
# Builds NotchMate.app (release) and optionally installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="build/NotchMate.app"
ADAPTER="Vendor/mediaremote-adapter"

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
cp Resources/face-animations.json "$APP/Contents/Resources/"
cp Resources/garmin_sync.py "$APP/Contents/Resources/"
cp -R "$ADAPTER/build/MediaRemoteAdapter.framework" "$APP/Contents/Resources/"

# Stable signing identity: macOS ties Accessibility / Automation / Keychain permissions to it,
# so they survive rebuilds. Ad-hoc signatures change on every build and silently lose permissions.
# Override with SIGN_ID=<sha1 or name>; SIGN_ID=- forces ad-hoc.
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')
  SIGN_ID=${SIGN_ID:--}
fi
# The adapter framework is loaded by /usr/bin/perl, not by the app — keep it ad-hoc.
codesign --force --deep --sign - "$APP/Contents/Resources/MediaRemoteAdapter.framework" >/dev/null
codesign --force --sign "$SIGN_ID" "$APP/Contents/MacOS/NotchMate" >/dev/null
codesign --force --sign "$SIGN_ID" "$APP" >/dev/null
echo "▸ Signed with: $([[ "$SIGN_ID" == "-" ]] && echo ad-hoc || security find-identity -v -p codesigning | grep "$SIGN_ID" | sed 's/.*"\(.*\)"/\1/')"
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
