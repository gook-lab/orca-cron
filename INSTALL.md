# OrcaCron 설치 가이드 — 에이전트에게 링크로 맡기기

Claude Code·Codex 같은 에이전트에게 이 문서 링크를 주고 아래처럼 말하면 설치까지 끝납니다.

> https://github.com/gook-lab/orca-cron/blob/main/INSTALL.md 보고 설치해줘

에이전트가 소스를 받아 이 맥에서 직접 빌드한 뒤 `~/Applications` 에 넣고, 로그인 때 자동으로 뜨도록 launchd 에 올립니다. 직접 빌드한 앱이라 Gatekeeper 경고가 뜨지 않고 관리자 권한도 필요 없습니다. 첫 빌드는 1~3분 걸립니다. 새 버전이 올라오면 메뉴 머리 줄 오른쪽에 「업데이트 N」이 보이고, 누르면 다시 빌드해 설치합니다. 버전별 변경 내용은 [CHANGELOG.md](CHANGELOG.md) 에 있습니다.

## 설치 뒤 사람이 할 일 — 메뉴 막대 확인 · 첫 예약

- 메뉴 막대 오른쪽에 시계 아이콘이 보이는지 확인해 주세요. 노치 때문에 가려졌다면 `open ~/Applications/OrcaCron.app` 으로 한 번 더 실행하면 같은 화면이 창으로 열립니다.
- 아이콘을 누르면 Orca 에 떠 있는 Claude Code 터미널이 보입니다. 터미널 줄의 📅+ 로 예약을, ✈ 로 한 번 보내기를 만듭니다. 자주 쓰는 작업은 「템플릿」에 적어 두고 할당하면 편합니다.

## 에이전트 설치 절차 — 순서대로 실행

이 절은 에이전트가 읽고 실행하는 지시문입니다.

지킬 것:

- `sudo` 를 쓰지 않는다. 시스템 설정이나 다른 앱 설정은 사용자에게 묻기 전에 바꾸지 않는다.
- 토큰·자격 증명 파일(`auth.json`, `.credentials*`, 키체인 등)을 읽거나 출력하지 않는다.
- 단계가 실패하면 거기서 멈추고, 명령과 출력을 그대로 사용자에게 보여 준다. 우회 설치를 시도하지 않는다.
- 사용자의 예약·템플릿(`~/.orca-cron/`)을 만들거나 지우지 않는다. 설치는 앱만 다룬다.

### 1. 사전 확인 — macOS 15 이상 · Swift 6 · Orca

```bash
sw_vers -productVersion   # 15.0 이상
xcode-select -p           # 경로가 나와야 한다
swift --version           # Swift version 6.x 이상
ls -d /Applications/Orca*.app ~/Applications/Orca*.app 2>/dev/null
```

- macOS 가 15 미만이면 중단하고 사용자에게 알린다.
- `xcode-select -p` 가 실패하면 `xcode-select --install` 을 실행한다. 설치 창이 뜨므로 사용자에게 「설치」를 눌러 달라고 하고, 끝났다고 하면 위 확인을 다시 한다.
- Swift 가 5.x 면 Command Line Tools 가 오래된 것이다. 사용자에게 시스템 설정 → 일반 → 소프트웨어 업데이트에서 Command Line Tools 를 올려 달라고 하고 중단한다.
- Orca 앱이 없으면 중단하고 사용자에게 알린다. OrcaCron 은 Orca 에 들어 있는 `orca` CLI 로만 터미널을 다룬다.

### 2. 소스 받기 — 이미 있으면 갱신

```bash
DIR="${ORCA_CRON_DIR:-$HOME/Developer/orca-cron}"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
else
  git clone https://github.com/gook-lab/orca-cron.git "$DIR"
fi
```

- `pull --ff-only` 가 실패하면(로컬 수정이 있음) 덮어쓰지 말고 사용자에게 알린다.
- 이 폴더를 지우면 앱의 「업데이트」가 동작하지 않는다. 앱이 빌드할 때 이 경로를 기억한다.

### 3. 빌드 · 설치 — 점검 통과 뒤 launchd 등록

```bash
cd "$DIR" && ./build.sh install
```

- 빌드 뒤 판정 규칙 점검이 돌고 `✓ 점검 N개 통과` 가 나와야 설치로 넘어간다. 실패하면 설치하지 않고 멈춘다.
- 마지막 줄이 `installed ~/Applications/OrcaCron.app (launchd lab.gook.orcacron)` 이면 성공이다. 앱은 바로 실행된다.
- 이미 설치돼 있으면 스크립트가 지금 앱을 끄고 새 빌드로 바꾼다. 예약 데이터는 그대로 남는다.

### 4. 받는 Claude Code 권한 — 결과 명령 허용 (사용자에게 먼저 묻기)

예약이 보낸 작업 끝에는 `OrcaCron finish …` 결과 명령이 붙는다. 일반 권한 모드의 Claude Code 는 이 명령에서 「실행할까요?」 창을 띄우고 멈춘다. 그러면 메뉴에 「권한 확인 창에서 멈춤」이 뜨고, 아무도 누르지 않으면 6시간 뒤 「결과 없음」으로 닫힌다.

사용자에게 "결과 명령을 묻지 않고 실행하도록 ~/.claude/settings.json 의 permissions.allow 에 한 줄 추가할까요?"라고 묻는다. 허락하면 아래를 실행하고, 거절하면 건너뛴다(메뉴 ⋯ → 「결과 명령 허용 규칙 복사」로 나중에 직접 넣을 수 있다).

```bash
RULE="Bash($HOME/Applications/OrcaCron.app/Contents/MacOS/OrcaCron finish:*)"
python3 - "$RULE" <<'PY'
import json, os, sys
path = os.path.expanduser("~/.claude/settings.json")
data = json.load(open(path)) if os.path.exists(path) else {}
allow = data.setdefault("permissions", {}).setdefault("allow", [])
if sys.argv[1] in allow:
    print("이미 있음")
else:
    allow.append(sys.argv[1])
    json.dump(data, open(path, "w"), ensure_ascii=False, indent=2)
    print("추가함:", sys.argv[1])
PY
```

- 이 규칙은 결과 명령 하나만 허용한다. 템플릿 안의 작업(파일 수정·git 등)이 권한을 물으면 그때도 멈추고, 메뉴에 같은 표시가 뜬다.
- `settings.json` 이 JSON 으로 읽히지 않으면 고치지 말고 사용자에게 알린다.

### 5. 동작 확인 — launchd · 예약 목록 · 화면 그림

```bash
launchctl print "gui/$(id -u)/lab.gook.orcacron" | grep -E "state =|pid ="
~/Applications/OrcaCron.app/Contents/MacOS/OrcaCron status
~/Applications/OrcaCron.app/Contents/MacOS/OrcaCron preview "${TMPDIR:-/tmp}/orca-cron-check.png"
```

- 첫 줄에 `state = running` 과 pid 가 보여야 한다.
- `status` 는 예약 목록을 찍는다. 처음 설치면 아무것도 나오지 않는 것이 정상이다.
- `preview` 는 메뉴 화면을 PNG 로 저장하고 경로를 출력한다(아무것도 보내지 않는다). 이미지를 볼 수 있으면 Orca 터미널 목록이 그려졌는지 확인한다. 「Orca 에 떠 있는 Claude Code 터미널이 없습니다」가 보이면 Orca 가 꺼져 있거나 Claude Code 터미널이 없는 것이다.
- 사용자에게 메뉴 막대 시계 아이콘이 보이는지 물어본다.

### 6. 결과 보고

설치 경로, 소스 버전(`git -C "$DIR" log --oneline -1`), 4단계 권한 규칙을 넣었는지, 5단계 확인 결과, 「설치 뒤 사람이 할 일」을 짧게 알린다.

## 업데이트 — 메뉴의 「업데이트 N」

앱이 켜진 뒤 20초, 그다음 30분마다(팝업을 열 때도 10분이 지났으면) 소스 폴더에서 `git fetch` 로 새 커밋을 확인합니다. 앱 코드가 바뀐 커밋이 있으면 머리 줄 오른쪽에 「업데이트 N」이 뜨고, 누르면 `git pull --ff-only && ./build.sh install` 을 돌린 뒤 앱이 다시 켜집니다. 에이전트에게 "OrcaCron 업데이트해줘"라고 해도 2~3단계를 다시 돌리면 됩니다.

## 삭제 — 앱 · launchd · 데이터

```bash
launchctl bootout "gui/$(id -u)/lab.gook.orcacron"
rm -f ~/Library/LaunchAgents/lab.gook.orcacron.plist
rm -rf ~/Applications/OrcaCron.app
```

예약과 템플릿은 `~/.orca-cron` 에 남습니다. 필요 없으면 따로 지워 주세요. 소스 폴더(`~/Developer/orca-cron`)도 따로 지우면 됩니다.

## 자주 막히는 곳 — 증상별 원인 · 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| 메뉴 막대에 아이콘이 없음 | 메뉴 막대가 노치까지 차서 새 아이콘이 가려짐 | `open ~/Applications/OrcaCron.app` 으로 창 열기, 또는 ⌘ 를 누른 채 안 쓰는 아이콘을 메뉴 막대 밖으로 끌어내기 |
| `xcrun: error: invalid active developer path` | Command Line Tools 없음 | 1단계의 `xcode-select --install` |
| `swift build` 가 `tools version` 오류 | Swift 5.x | Command Line Tools 업데이트 |
| 「Orca CLI 를 찾지 못했습니다」 | Orca 가 `/Applications`·`~/Applications` 밖에 있음 | `ORCA_BIN` 에 `orca` 경로를 주고 다시 실행, 또는 Orca 를 `/Applications` 로 옮기기 |
| 「권한 확인 창에서 멈춤」 | 받는 Claude Code 가 결과 명령이나 작업 중 명령의 실행 허락을 기다림 | 그 터미널에서 허용. 결과 명령은 4단계 규칙을 넣으면 다시 묻지 않음 |
| 「터미널은 끝났는데 결과 기록이 없음」 | 받는 쪽이 결과 명령을 부르지 않고 끝냄(템플릿에 결과를 남기지 말라는 문장이 있거나, 작업이 중간에 멈춤) | 그 터미널의 마지막 답을 확인하고 템플릿 문장을 고치기 |
| 알림이 「스크립트 편집기」 이름으로 옴 | 직접 빌드한 앱은 알림 센터 권한을 받지 못해 `osascript` 로 띄움 | 정상 동작. 아예 안 오면 시스템 설정 → 알림 → 스크립트 편집기 켜기. ⋯ 메뉴 「알림」에서 끌 수 있음 |
| 예약이 계속 「대기 중」 | 터미널이 일하는 중이거나, 입력 칸에 글이 있거나, 질문 창이 떠 있음 | 그 터미널을 비워 두면 30초 안에 들어감. 60분이 지나면 「건너뜀」 |
| 「터미널 없음 — 편집에서 다시 고르세요」 | 그 터미널 탭을 닫음 | 예약 편집에서 다른 터미널을 고르기 |
| 업데이트를 눌렀는데 그대로임 | 소스 폴더에 로컬 수정이 있어 `git pull --ff-only` 실패 | 머리 줄 아래 빨간 실패 이유와 `~/Library/Logs/OrcaCron-update.log` 확인 |
