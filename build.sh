#!/usr/bin/env bash
# 사용법: ./build.sh            → build/OrcaCron.app (이 맥 아키텍처)
#         ./build.sh install    → ~/Applications 로 복사하고 launchd(로그인 시 자동 실행)에 올린다
set -euo pipefail
cd "$(dirname "$0")"

APP=build/OrcaCron.app
LABEL=lab.gook.orcacron
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release
# 판정 규칙 확인(Sources/SchedulerCheck). 실패하면 설치하지 않는다
.build/release/SchedulerCheck

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/OrcaCron "$APP/Contents/MacOS/OrcaCron"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" # 다시 그리려면 scripts/make-icon.swift
# 버전 = 1.<커밋 수>. 앱이 업데이트를 스스로 확인하도록 소스 폴더와 커밋을 적어 둔다(Sources/OrcaCron/Updater.swift)
COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 1.$COUNT" -c "Set :CFBundleVersion $COUNT" \
  -c "Add :OrcaCronCommit string $(git rev-parse HEAD 2>/dev/null)" \
  -c "Add :OrcaCronSourceDir string $(pwd)" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP (v1.$COUNT)"

if [[ "${1:-}" == "install" ]]; then
  # 앱의 「업데이트」가 이 스크립트를 띄운 경우 앱이 조상 프로세스다. AbandonProcessGroup 덕에 앱이 꺼져도 이 스크립트는 남는다
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -a -x OrcaCron 2>/dev/null || true
  mkdir -p ~/Applications ~/Library/LaunchAgents
  rm -rf ~/Applications/OrcaCron.app
  cp -R "$APP" ~/Applications/
  # 빌드본을 남기면 Launch Services 에 앱이 둘 등록된다
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$HOME/Applications/OrcaCron.app/Contents/MacOS/OrcaCron</string></array>
    <key>RunAtLoad</key><true/>
    <!-- 메뉴의 「종료」(정상 종료)는 그대로 두고, 비정상 종료만 다시 띄운다 -->
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>AbandonProcessGroup</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "installed ~/Applications/OrcaCron.app (launchd $LABEL)"
fi
