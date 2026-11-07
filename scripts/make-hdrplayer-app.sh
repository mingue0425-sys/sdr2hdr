#!/bin/bash
# Builds HDRPlayer.app in the repository root, so videos open in HDRPlayer by
# double-click or Finder's "Open With". Everything stays inside this folder:
# the app is assembled from .build/release and signed ad hoc (no network, no
# install). Converted WebM/VP9 copies go to .build/converted.
#
# Usage: scripts/make-hdrplayer-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
export TMPDIR="$ROOT/.build/tmp/" CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"
mkdir -p "$TMPDIR"
swift build -c release --product HDRPlayer \
  --cache-path .swiftpm/cache --config-path .swiftpm/config --security-path .swiftpm/security >/dev/null

APP="$ROOT/HDRPlayer.app"
STAGE="$ROOT/.build/HDRPlayer.app.staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/HDRPlayer "$STAGE/Contents/MacOS/HDRPlayer"
# SwiftPM resource bundles (Metal shaders) are looked up in Contents/Resources.
for bundle in .build/release/*.bundle; do
  cp -R "$bundle" "$STAGE/Contents/Resources/"
done
VERSION=$(git describe --always --dirty 2>/dev/null || echo dev)
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>HDRPlayer</string>
  <key>CFBundleIdentifier</key><string>local.sdr2hdr.HDRPlayer</string>
  <key>CFBundleName</key><string>HDRPlayer</string>
  <key>CFBundleDisplayName</key><string>HDRPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Safari의 현재 탭에서 유튜브 영상 주소를 읽어 HDR로 재생합니다.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>local.sdr2hdr.HDRPlayer.open</string>
      <key>CFBundleURLSchemes</key><array><string>hdrplayer</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
        <string>com.apple.m4v-video</string>
        <string>org.webmproject.webm</string>
        <string>org.matroska.mkv</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Image</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.image</string>
        <string>public.jpeg</string>
        <string>public.png</string>
        <string>public.heic</string>
        <string>public.tiff</string>
        <string>org.webmproject.webp</string>
        <string>com.compuserve.gif</string>
      </array>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>org.webmproject.webm</string>
      <key>UTTypeDescription</key><string>WebM video</string>
      <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>webm</string></array>
            <key>public.mime-type</key><array><string>video/webm</string></array></dict>
    </dict>
    <dict>
      <key>UTTypeIdentifier</key><string>org.matroska.mkv</string>
      <key>UTTypeDescription</key><string>Matroska video</string>
      <key>UTTypeConformsTo</key><array><string>public.movie</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>mkv</string></array>
            <key>public.mime-type</key><array><string>video/x-matroska</string></array></dict>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$STAGE" 2>/dev/null
codesign --verify --deep "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
# Point LaunchServices at the new build (as Finder does when it sees the app).
# Without this, the first launch after a rebuild fails with -10810 because the
# ad hoc signature changed. Nothing is copied outside this folder.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "built $APP ($VERSION)"
