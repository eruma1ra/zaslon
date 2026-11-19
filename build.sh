#!/bin/sh
# Builds build/Zaslon.app. A rebuild changes the app's signature, and the system then refuses to start the launch
# agent until it is registered again: open the app once by hand after every build and it repairs that itself.
# Check the logic with: build/Zaslon.app/Contents/MacOS/Zaslon --selftest
#   ./build.sh       the app for this Mac
#   ./build.sh dmg   the app for both chip families, packed as build/Zaslon-<version>.dmg for a release
# SWIFT_BUILD_FLAGS is passed on to `swift build` (Homebrew needs --disable-sandbox).
set -e
cd "$(dirname "$0")"
if [ "$1" = dmg ]; then
    for arch in arm64 x86_64; do swift build -c release --triple "$arch-apple-macosx14.0" $SWIFT_BUILD_FLAGS; done
    lipo -create .build/arm64-apple-macosx/release/Zaslon .build/x86_64-apple-macosx/release/Zaslon -output .build/Zaslon-universal
    BINARY=.build/Zaslon-universal
else
    swift build -c release $SWIFT_BUILD_FLAGS
    BINARY=.build/release/Zaslon
fi
APP=build/Zaslon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/Zaslon"
mkdir -p "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/" # drawn by icon.swift
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.zaslon</string>
<key>CFBundleName</key><string>Zaslon</string>
<key>CFBundleExecutable</key><string>Zaslon</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.1</string>
<key>CFBundleVersion</key><string>1.3.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
# The launch agent: started by the system at login and again after a crash. A clean exit (the menu's "Выйти") stays out.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/local.zaslon.agent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.zaslon.agent</string>
<key>BundleProgram</key><string>Contents/MacOS/Zaslon</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>1</integer>
<key>ProcessType</key><string>Interactive</string>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF
codesign --force --sign - "$APP"
echo "built $APP"
if [ "$1" = dmg ]; then
    rm -rf build/dmg
    mkdir -p build/dmg
    cp -R "$APP" build/dmg/
    ln -s /Applications build/dmg/Applications # drag the app onto it
    hdiutil create -quiet -volname Zaslon -srcfolder build/dmg -ov -format UDZO build/Zaslon-1.3.1.dmg
    rm -rf build/dmg
    echo "built build/Zaslon-1.3.1.dmg"
fi
