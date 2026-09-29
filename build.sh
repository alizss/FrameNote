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
codesign --force --sign - "$APP_STAGE"
codesign --verify --deep --strict "$APP_STAGE"
rm -rf "$APP_DIR" FrameNote.app
mv "$APP_STAGE" "$APP_DIR"
ln -s "$APP_DIR" FrameNote.app
codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR (linked as ${PWD}/FrameNote.app)"
