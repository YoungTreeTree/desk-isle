#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$root/build/macos}"
app="$output/DeskIsle.app"
font="${DESKISLE_MISANS_FONT:-$root/build/assets/MiSans-Regular.ttf}"
if [[ ! -f "$font" ]]; then
  print -u2 "找不到 MiSans-Regular.ttf。请将小米官网字体放到 $font，或用 DESKISLE_MISANS_FONT 指定路径。"
  exit 1
fi
python="$(uv python find 3.11)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
uv pip install --python "$python" --target "$app/Contents/Resources/garmin-packages" \
  --requirements "$root/helpers/garmin/garmin-requirements.txt"
"$python" "$root/tools/package-python.py" --python "$python" --destination "$app/Contents/Resources/runtime"
swift build --package-path "$root" --scratch-path "$root/build/swiftpm" -c release --product DeskIsle
bin="$(swift build --package-path "$root" --scratch-path "$root/build/swiftpm" -c release --show-bin-path)"
cp "$bin/DeskIsle" "$app/Contents/MacOS/DeskIsle"
ditto "$bin/Miucs_MiucsCore.bundle" "$app/Contents/Resources/Miucs_MiucsCore.bundle"
ditto "$bin/DeskIsle_DeskIsle.bundle" "$app/Contents/Resources/DeskIsle_DeskIsle.bundle"
swiftc -parse-as-library -swift-version 6 -O -target "$(uname -m)-apple-macosx14.0" \
  "$root/helpers/notifications/DeskIsleCLI.swift" "$root/macos/Widgets/Notifications/NotificationEvent.swift" "$root/macos/Widgets/Notifications/NotificationSocket.swift" \
  -o "$app/Contents/Helpers/deskisle"
cp "$root/resources/wallpaper.jpg" "$root/helpers/garmin/garmin_snapshot.py" "$root/helpers/garmin/garmin_auth.py" "$root/helpers/garmin/garmin_session.py" "$root/helpers/notifications/install-codex-notifications.py" "$app/Contents/Resources/"
cp "$root/resources/DeskIsle.icns" "$app/Contents/Resources/DeskIsle.icns"
cp "$font" "$app/Contents/Resources/MiSans-Regular.ttf"
cp "$root/LICENSE" "$root/THIRD_PARTY_LICENSE_CODEX_USAGE.txt" "$root/THIRD_PARTY_LICENSE_WIDGET_FONT.txt" "$root/THIRD_PARTY_LICENSE_MESHOPTIMIZER.txt" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.deskisle.layout</string>
  <key>CFBundleName</key><string>桌屿</string>
  <key>CFBundleDisplayName</key><string>桌屿</string>
  <key>CFBundleExecutable</key><string>DeskIsle</string>
  <key>CFBundleIconFile</key><string>DeskIsle.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSAudioCaptureUsageDescription</key><string>桌屿分析系统音频，让小屏桌宠随音乐活动。</string>
  <key>NSScreenCaptureUsageDescription</key><string>桌屿只采集系统音频用于桌宠，不保存屏幕或音频。</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/deskisle"
codesign --force --sign - "$app/Contents/Resources/runtime/bin/python3.11"
identity="${DESKISLE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  if security find-identity -p codesigning | rg -q '"Miucs Dev"'; then identity="Miucs Dev"; else identity="-"; fi
fi
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
print -r -- "$app"
