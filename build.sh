#!/bin/zsh
# Builds a release binary and wraps it in CC360Framer.app (ad-hoc signed).
set -e
cd "$(dirname "$0")"
swift build -c release
APP=CC360Framer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CC360Framer "$APP/Contents/MacOS/"
# App icon: SwiftPM cannot compile Icon Composer .icon files, so actool does it here
# (Assets.car for macOS 26+, AppIcon.icns fallback). Without it the app just has no icon.
ICON="$PWD/Sources/CC360Framer/Assets/AppIcon.icon"  # absolute: actool resolves relative paths oddly
ICONKEYS=""
ICONTMP=$(mktemp -d)
if [[ -d "$ICON" ]] && xcrun actool "$ICON" --compile "$ICONTMP" --platform macosx \
     --minimum-deployment-target 14.0 --app-icon AppIcon \
     --output-partial-info-plist "$ICONTMP/partial.plist" --output-format human-readable-text \
     --notices --warnings --errors >"$ICONTMP/actool.log" 2>&1 \
   && [[ -f "$ICONTMP/Assets.car" ]]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$ICONTMP/Assets.car" "$APP/Contents/Resources/"
  [[ -f "$ICONTMP/AppIcon.icns" ]] && cp "$ICONTMP/AppIcon.icns" "$APP/Contents/Resources/"
  ICONKEYS='<key>CFBundleIconName</key><string>AppIcon</string><key>CFBundleIconFile</key><string>AppIcon</string>'
else
  echo "Note: could not compile the app icon (actool failed or $ICON missing); the app is built without an icon."
fi
rm -rf "$ICONTMP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CC360Framer</string>
  <key>CFBundleIdentifier</key><string>dev.cc360framer.app</string>
  <key>CFBundleExecutable</key><string>CC360Framer</string>
  $ICONKEYS
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
    <key>NSDocumentClass</key><string>CC360VideoDocument</string>
    <key>CFBundleTypeExtensions</key><array><string>360</string></array>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>dev.cc360framer.gopro-360</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP — run: open $APP   (or: $APP/Contents/MacOS/CC360Framer GS010074.360)"
