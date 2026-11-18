#!/bin/sh
# Builds build/Zaslon.app. A rebuild changes the app's signature, and the system then refuses to start the launch
# agent until it is registered again: open the app once by hand after every build and it repairs that itself.
# Check the logic with: build/Zaslon.app/Contents/MacOS/Zaslon --selftest
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/Zaslon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Zaslon "$APP/Contents/MacOS/"
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
<key>CFBundleShortVersionString</key><string>0.1</string>
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
