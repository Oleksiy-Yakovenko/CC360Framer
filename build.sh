#!/bin/zsh
# Builds a release binary and wraps it in CC360Framer.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=CC360Framer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CC360Framer "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CC360Framer</string>
  <key>CFBundleIdentifier</key><string>dev.cc360framer.app</string>
  <key>CFBundleExecutable</key><string>CC360Framer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UTImportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>dev.cc360framer.gopro-360</string>
    <key>UTTypeDescription</key><string>GoPro 360 video</string>
    <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
    <key>UTTypeTagSpecification</key><dict>
      <key>public.filename-extension</key><array><string>360</string></array>
    </dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>GoPro 360 video</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>dev.cc360framer.gopro-360</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP — run: open $APP   (or: $APP/Contents/MacOS/CC360Framer GS010074.360)"
