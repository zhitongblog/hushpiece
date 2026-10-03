#!/bin/zsh
# Mac App Store build of 耳语同传 (sandboxed, -DAPPSTORE: no third-party driver guidance).
#
#   scripts/build-mas.sh          → dist-mas/Hushpiece-<ver>-<build>.pkg  (Apple Distribution, for upload)
#   scripts/build-mas.sh --dev    → dist-mas/dev/Hushpiece.app            (Apple Development, same sandbox; runs locally)
#
# The provisioning profile comes from `scripts/asc.py setup` (dist/Hushpiece_MAS.provisionprofile).
# MAS_BUILD_NUMBER: monotonic CFBundleVersion; defaults to the git commit count.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=${1:-dist}
VERSION=$(grep -m1 'let version' Sources/Hushpiece/Main.swift | sed -E 's/.*"(.*)".*/\1/')
BUILD=${MAS_BUILD_NUMBER:-$(git rev-list --count HEAD)}
TEAM=6NQM3XP5RF
APPID=app.hushpiece.Hushpiece
PROFILE=dist/Hushpiece_MAS.provisionprofile

swift build -c release --arch arm64 -Xswiftc -DAPPSTORE --build-path .build-mas
BIN=$(swift build -c release --arch arm64 -Xswiftc -DAPPSTORE --build-path .build-mas --show-bin-path)/hushpiece

OUTDIR=dist-mas; [[ $MODE == --dev ]] && OUTDIR=dist-mas/dev
APP=$OUTDIR/Hushpiece.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
cp "$BIN" "$APP/Contents/MacOS/hushpiece"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>${APPID}</string>
  <key>CFBundleName</key><string>Hushpiece</string>
  <key>CFBundleDisplayName</key><string>耳语同传</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>hushpiece</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSMicrophoneUsageDescription</key><string>耳语同传用麦克风识别你说的话并翻译。声音只在这台 Mac 上处理，不会上传或保存。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>耳语同传使用系统的本机语音识别，把通话内容转成字幕。</string>
  <key>NSAudioCaptureUsageDescription</key><string>耳语同传需要听到会议软件里对方的声音，才能显示字幕。只取声音，不保存音频。</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 xiangdong li</string>
</dict></plist>
PLIST
printf '"CFBundleDisplayName" = "耳语同传";\n"CFBundleName" = "耳语同传";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "Hushpiece";\n"CFBundleName" = "Hushpiece";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"

ENT=$OUTDIR/entitlements.plist
cat > "$ENT" <<ENTX
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
$( [[ $MODE == --dev ]] || printf '  <key>com.apple.application-identifier</key><string>%s.%s</string>\n  <key>com.apple.developer.team-identifier</key><string>%s</string>\n' $TEAM $APPID $TEAM )
</dict></plist>
ENTX

if [[ $MODE == --dev ]]; then
  ID=$(security find-identity -v -p codesigning | grep -m1 "Apple Development: xiangdong li" | sed -E 's/.*"(.*)"/\1/')
  codesign --force --options runtime --entitlements "$ENT" -s "$ID" "$APP"
  codesign --verify --strict "$APP" && echo "dev sandbox build: $APP (signed by $ID)"
  exit 0
fi

[[ -f $PROFILE ]] || { echo "missing $PROFILE — run: source scripts/asc-env.sh && scripts/asc.py setup" >&2; exit 1; }
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
APPCERT=$(security find-identity -v -p codesigning | grep -m1 "Apple Distribution: xiangdong li" | sed -E 's/.*"(.*)"/\1/')
INSTCERT=$(security find-identity -v | grep -m1 "3rd Party Mac Developer Installer: xiangdong li" | sed -E 's/.*"(.*)"/\1/')
codesign --force --options runtime --entitlements "$ENT" -s "$APPCERT" "$APP"
codesign --verify --strict --verbose=2 "$APP"
PKG=$OUTDIR/Hushpiece-${VERSION}-${BUILD}.pkg
productbuild --component "$APP" /Applications --sign "$INSTCERT" "$PKG"
echo "MAS package: $PKG  (version $VERSION build $BUILD)"
