#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build -c "$configuration"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$PWD/dist/Spark Manager.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/SparkManager" "$app_dir/Contents/MacOS/SparkManager"
cp Sources/SparkMonitor/Resources/collector.py "$app_dir/Contents/Resources/collector.py"
cp Sources/SparkMonitor/Resources/windows-collector.ps1 Sources/SparkMonitor/Resources/windows-native.cs "$app_dir/Contents/Resources/"
cp LICENSE docs/THIRD_PARTY.md "$app_dir/Contents/Resources/"
swift scripts/icon.swift "$PWD/dist/AppIcon.iconset"
iconutil -c icns "$PWD/dist/AppIcon.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>SparkManager</string>
<key>CFBundleIdentifier</key><string>org.sparkmonitor.native.preview</string>
<key>CFBundleName</key><string>Spark Manager</string>
<key>CFBundleDisplayName</key><string>Spark Manager</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$PWD/dist/Spark-Manager-macOS-arm64.zip"
printf '%s\n' "$app_dir"
