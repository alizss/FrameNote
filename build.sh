#!/bin/zsh
set -eu
cd "${0:A:h}"
BUILD_DIR="/private/tmp/framenote-build-$UID"
swift build -c release --scratch-path "$BUILD_DIR" -j 1
BIN_DIR="$(swift build --show-bin-path -c release --scratch-path "$BUILD_DIR")"
APP_STAGE="$BUILD_DIR/FrameNote.app"
APP_DIR="$HOME/Applications/FrameNote.app"
rm -rf "$APP_STAGE"
mkdir -p "$APP_STAGE/Contents/MacOS" "$HOME/Applications"
cp -X "$BIN_DIR/FrameNote" "$APP_STAGE/Contents/MacOS/FrameNote"
cp -X Info.plist "$APP_STAGE/Contents/Info.plist"
xattr -cr "$APP_STAGE"

# TCC ties screen-recording consent to the app's designated code requirement.
# Ad-hoc signatures use the binary's cdhash as that requirement, so every
# rebuild looks like a different app and triggers another privacy prompt.
SIGNING_IDENTITY="${FRAMENOTE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/ { print $2; exit }')"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" "$APP_STAGE"
  echo "Signed with stable identity: $SIGNING_IDENTITY"
else
  codesign --force --sign - "$APP_STAGE"
  echo "Warning: no Apple Development identity found; ad-hoc signing may cause macOS to ask for Screen Recording permission again after rebuilds."
fi
codesign --verify --deep --strict "$APP_STAGE"
rm -rf "$APP_DIR" FrameNote.app
mv "$APP_STAGE" "$APP_DIR"
ln -s "$APP_DIR" FrameNote.app
codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR (linked as ${PWD}/FrameNote.app)"
