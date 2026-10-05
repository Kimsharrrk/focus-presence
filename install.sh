#!/bin/sh
# 빌드 후 로그인 시 자동 실행되는 LaunchAgent로 등록한다. 제거: ./install.sh --uninstall
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
LABEL="com.focustracker.collector"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$1" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "제거했습니다. 기록 데이터는 ~/Library/Application Support/FocusTracker 에 그대로 남아 있습니다."
  exit 0
fi

./build.sh
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$ROOT/build/focus-collector</string>
    <string>$ROOT/server/server.mjs</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "설치 완료. 메뉴바에 ● 표시가 보이면 기록 중입니다. 대시보드: http://localhost:4317"
