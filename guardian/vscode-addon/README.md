# VS Code 애드온 (오프라인 · macOS arm64)

인터넷도 VS Code도 없는 현장 Mac에, 위키 편집용 VS Code + Foam + Claude Code 확장을
얹히는 소형 꾸러미입니다. 이미 `~/llm-wiki/wiki` 위키가 설치돼 있다고 가정합니다.

> 통합 번들에도 이 폴더가 `vscode-addon/` 으로 들어 있고, `install-all.sh` 6/7 단계가
> 자동으로 돌립니다(`--no-vscode` 로 생략, `--no-vscode-app` 이면 앱은 두고 확장·설정만,
> `--vscode-app-dir=DIR` 로 앱 위치). 쓸 수 없는 `/Applications` 에 VS Code 가 이미 있으면
> 그 앱을 그대로 쓰고 `--no-app` 으로 설치합니다. 이 꾸러미를 따로 옮기는 것은
> 이미 설치된 Mac 에 더하거나 새 버전으로 바꿀 때입니다.

## 구성

| 파일 | 내용 |
|---|---|
| `app/VSCode-darwin-arm64.dmg` | VS Code (Microsoft 서명·공증 확인됨, 봉인은 인스톨러가 재검증) |
| `extensions/foam.foam-vscode-*.vsix` | Foam — `[[id]]` 위키 링크·템플릿 |
| `extensions/Anthropic.claude-code-*-darwin-arm64.vsix` | Claude Code 확장 (자체 `claude` 바이너리 포함, Anthropic 서명) |
| `wiki-workspace/` | 위키 폴더용 `.vscode/settings.json`, `.foam/templates/new-note.md` |
| `install-vscode.sh`, `MANIFEST.env`, `SHA256SUMS` | 설치 스크립트와 무결성 정보 |

## 설치

```bash
shasum -a 256 -c SHA256SUMS   # 먼저 무결성 확인
./install-vscode.sh --dry-run # 할 일 미리보기
./install-vscode.sh           # 설치
```

Claude 설정값은 `~/.config/claude-lms/env`에서 읽어
`claudeCode.environmentVariables`로 만들어 줍니다(토큰은 절대 복사하지 않고
`ANTHROPIC_AUTH_TOKEN=lmstudio` 고정). 키트가 없거나 `CLAUDE_LMS_MODEL`이 비어 있으면
Claude 항목만 건너뛰고 오프라인 설정만 씁니다.

모델 선택 목록에 넣을 모델은 `./install-vscode.sh --pick-models`로 고르거나,
env 파일에 `CLAUDE_LMS_PICKER='모델1 모델2'`처럼 적어 둡니다(1~4개, 순서대로 Opus·Sonnet·Haiku·Fable 행).
아직 Spark에 올라와 있지 않은 모델은 쓰기 전에 `spark-model use <모델>`이 필요합니다
(몇 분 걸리고 모든 사용자에게 영향). 통합 번들에서는 `install-all.sh --vscode-pick-models`.
통합 번들은 라우터를 기본으로 설치하고, 이 줄이 없으면 `CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct'`를 넣습니다
(Opus `spark-large`, Sonnet `qwen3-coder`, Haiku `local-fast`, Fable `qwen3-instruct`). 확장은 라우터가 꺼져 있을 때
LM Studio로 넘어가지 않습니다.

## 옵션

| 옵션 | 동작 |
|---|---|
| `--dry-run` | 모든 행동을 출력만 하고 변경 없음 |
| `--no-app` / `--no-extensions` / `--no-settings` / `--no-wiki` | 해당 단계 건너뛰기 |
| `--wiki=DIR` | 위키 폴더 (기본 `~/llm-wiki/wiki`) |
| `--app-dir=DIR` | 앱 설치 위치 (기본 `/Applications`) |
| `--user-data-dir=DIR` / `--extensions-dir=DIR` | 격리 테스트용 (`code` CLI에 전달) |
| `--pick-models` | 라우터의 모델 목록(Spark 설치 모델·로컬 모델)을 번호로 보여 주고, 확장의 모델 선택 목록에 넣을 모델을 1~4개 고름. 순서대로 Opus·Sonnet·Haiku·Fable 행. 라우터 모드에서만 동작 |

## Mac에 생기는 변화

- `/Applications/Visual Studio Code.app` — 이미 같거나 더 새 버전이 있으면 그대로 둠.
  이전 버전은 `Visual Studio Code.old-<버전>.app`으로 옮겨짐 (삭제하지 않음)
- 확장 2개(Foam, Claude Code) 설치 — 이미 같거나 더 새 버전이 설치돼 있으면 그대로 둠
  (현장 Mac의 더 새 Claude Code 확장을 핀 버전으로 되돌리지 않음). Claude 바이너리의
  `com.apple.quarantine`만 제거
- VS Code 사용자 설정: 텔레메트리·자동업데이트 끄기 등 오프라인 항목 + Claude 환경변수.
  기존 `settings.json`에 내용이 있으면 덮어쓰지 않고 옆에 `settings.vscode-addon.jsonc`로
  두고 붙여넣기 안내
- 위키 폴더의 `.vscode/settings.json`, `.foam/templates/new-note.md` — 대상이 이미 있으면
  `*.vscode-addon` 파일로 옆에 둠. 노트 본문은 절대 건드리지 않음

## 되돌리기

- 앱: `/Applications`에서 `Visual Studio Code.app`을 휴지통으로
- 확장: `code --uninstall-extension foam.foam-vscode` / `code --uninstall-extension anthropic.claude-code`
- 설정: `settings.json`에서 `claudeCode.*` 항목과 위 오프라인 항목 삭제 (사이드 파일도)
- 위키: `.vscode/`, `.foam/` 폴더 삭제

## 연동 안내

- 단독 꾸러미로 깔 때 터미널의 `claude-lms`는 여전히 Claude Code 키트(통합 번들이면
  4단계)가 필요하고, 확장은 자체 `claude` 바이너리를 가지고 갑니다.
- 첫 실행: `"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ~/llm-wiki/wiki`
  → "Do you trust the authors?"에 **Trust** (Restricted Mode면 Claude 확장이 꺼짐).
  Claude 패널은 편집기 제목 표시줄/활동 표시줄의 스파크 아이콘.
- 라우터 모드에서는 claude-lms와 달리 라우터가 죽어도 LM Studio로 폴백하지 않습니다.
