#!/bin/zsh
# Build 耳语同传 (Hushpiece.app): menu bar app + the `hushpiece` CLI/MCP in one signed bundle.
#   scripts/build-app.sh            → dist/Hushpiece.app
#   scripts/build-app.sh --install  → also copy to /Applications and link `hushpiece` (+ legacy `calltrans`) into PATH
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(grep -m1 'let version' Sources/Hushpiece/Main.swift | sed -E 's/.*"(.*)".*/\1/')
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
swift build -c release
APP=dist/Hushpiece.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/zh-Hans.lproj" "$APP/Contents/Resources/en.lproj"
cp .build/release/hushpiece "$APP/Contents/MacOS/hushpiece"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.hushpiece.Hushpiece</string>
  <key>CFBundleName</key><string>Hushpiece</string>
  <key>CFBundleDisplayName</key><string>Hushpiece</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>hushpiece</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSMicrophoneUsageDescription</key><string>Hushpiece uses the microphone to recognise and translate what you say. Audio is processed on this Mac and never uploaded or saved.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Hushpiece uses on-device speech recognition to turn the meeting into subtitles.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Hushpiece needs to hear the other side of your meeting to show subtitles. Audio only; nothing is saved.</string>
  <key>NSHumanReadableCopyright</key><string>耳语同传 Hushpiece</string>
</dict></plist>
PLIST
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STR'
"CFBundleDisplayName" = "耳语同传";
"CFBundleName" = "耳语同传";
"NSMicrophoneUsageDescription" = "耳语同传用麦克风识别你说的话并翻译。声音只在这台 Mac 上处理，不会上传或保存。";
"NSSpeechRecognitionUsageDescription" = "耳语同传使用系统的本机语音识别，把通话内容转成字幕。";
"NSAudioCaptureUsageDescription" = "耳语同传需要听到会议软件里对方的声音，才能显示字幕。只取声音，不保存音频。";
STR
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STR'
"CFBundleDisplayName" = "Hushpiece";
"CFBundleName" = "Hushpiece";
STR
cat > dist/entitlements.plist <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')}
codesign --force --options runtime --timestamp --entitlements dist/entitlements.plist -s "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP" && echo "built $APP ($VERSION build $BUILD), signed by: ${IDENTITY:-ad-hoc}"

if [[ "${1:-}" == "--install" ]]; then
  pkill -f "/Applications/Hushpiece.app/Contents/MacOS/hushpiece" 2>/dev/null || true
  rm -rf /Applications/Hushpiece.app
  cp -R "$APP" /Applications/Hushpiece.app
  BIN="$(brew --prefix 2>/dev/null || echo /usr/local)/bin"
  ln -sf /Applications/Hushpiece.app/Contents/MacOS/hushpiece "$BIN/hushpiece"
  ln -sf /Applications/Hushpiece.app/Contents/MacOS/hushpiece "$BIN/calltrans"   # old name keeps working
  echo "installed /Applications/Hushpiece.app; $BIN/hushpiece -> app"
fi
