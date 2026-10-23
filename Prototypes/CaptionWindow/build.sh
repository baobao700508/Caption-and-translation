#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/.build/CaptionWindowPrototypes.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.2 \
  -O CaptionProposals.swift PreviewApp.swift -o "$app/Contents/MacOS/CaptionWindowPrototypes"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.captiontranslation.window-proposals</string>
<key>CFBundleExecutable</key><string>CaptionWindowPrototypes</string>
<key>CFBundleName</key><string>字幕浮窗原型</string>
<key>CFBundleDisplayName</key><string>字幕浮窗原型</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf '原型已构建：%s\n' "$app"
