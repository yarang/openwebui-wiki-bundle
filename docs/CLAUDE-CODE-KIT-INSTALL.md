# Claude Code kit 설치 안내

Claude Code kit(`claude-code-kit-<버전>-<UTC시각>-macos-arm64.tar.gz`)을 받은 Mac에서 설치를 마치고 확인할 때까지의 순서를 정리한 문서다. 세부 설명은 기존 문서의 해당 절로 연결했다.

- 기준 kit: `claude-code-kit-2.1.325-20261115T0414Z-macos-arm64` (2026-11-15)
- 기준 설치처: 운영 Mac (claude-lms → llm-router `127.0.0.1:1240` → Spark, LM Studio는 폴백)

## 1. kit에 들어 있는 것

| 경로 | 내용 | 설치 위치 |
|---|---|---|
| `claude` | Anthropic 서명 Claude Code 바이너리 | `~/.local/share/claude/versions/<버전>`, 링크 `~/.local/bin/claude` |
| `claude-lms` | Claude Code를 LM Studio·llm-router로 돌리는 래퍼 | `~/.local/bin/claude-lms`, 설정 `~/.config/claude-lms/env` |
| `install-claude-code.sh` | 설치기 | — |
| `claude-kit/skills/{hwpx,docx,xlsx,pptx}` | 문서 skill과 skill-guard hook | `~/.claude/skills/<이름>` |
| `claude-kit/wheels/` | hwpx skill이 vendoring하는 python-hwpx 휠 | skill 안 |
| `llm-router/` | `router.py`, `spark-model`, `install-llm-router.sh`, `env.example`, `README.md` | `--with-router`일 때만 설치 |
| `VERSION`, `SHA256SUMS` | 버전, 파일별 해시 | — |

kit의 `llm-router/`에는 `tests/`·`spark/`가 없다. Spark 쪽 컨트롤러(spark-switch)는 Spark에서 저장소로 설치한다([LLM-ROUTER.md §2](LLM-ROUTER.md#2-설치-순서) 1단계).

## 2. 사전 조건

**공통**

- Apple Silicon Mac(macOS arm64), zsh.
- LM Studio를 한 번 실행해 두었고 서버가 `http://127.0.0.1:1234`에서 응답한다. claude-lms가 쓸 모델이 내려받아져 있다.
  - 모델 id는 Mac마다 다르다. `curl -s http://127.0.0.1:1234/v1/models`로 확인한다([INSTALL-ISSUES.md 1.10](INSTALL-ISSUES.md#110-모델-id가-mac마다-다름)).
- 같은 이름의 일반 파일이 `~/.local/bin/claude`에 있으면 설치기가 멈춘다. 공식 설치(심볼릭 링크)는 그대로 둔다([INSTALL-ISSUES.md 1.13](INSTALL-ISSUES.md#113-이미-설치된-claude와의-충돌)).

**skill을 설치할 때** (기본)

- guardian 번들의 venv `~/.guardian-llm/venv/bin/python`. 다른 python을 쓰려면 `CLAUDE_LMS_PY=/경로/python`을 앞에 붙여 실행한다.
- 오피스 skill(docx·xlsx·pptx)은 그 python이 해당 모듈을 import 할 수 있을 때만 설치된다([CLAUDE-LMS-MANUAL.md §11.2](CLAUDE-LMS-MANUAL.md#112-설치)).

**llm-router를 함께 설치할 때** (`--with-router` / `--router-load`)

- 위 python이 `fastapi`, `httpx`, `uvicorn`을 import 할 수 있어야 한다. guardian 번들의 venv에는 들어 있다. 없으면 설치기가 아무것도 쓰기 전에 멈춘다.
- Spark에 spark-switch 컨트롤러가 설치돼 있고, 이 Mac에서 `spark.local:8000`·`:8001`·`:8010`에 닿는다.
- Spark의 vLLM API 키와 교체 토큰(`SWITCH_TOKEN`)을 화면에 찍지 않고 옮길 방법이 있다(§5).

## 3. 파일 확인과 압축 풀기

새 폴더에 `<이름>.tar.gz`와 `<이름>.tar.gz.sha256` 두 파일을 놓는다.

```bash
shasum -a 256 -c <이름>.tar.gz.sha256 && tar xzf <이름>.tar.gz && cd <이름> && shasum -a 256 -c SHA256SUMS
```

- 앞의 검사가 실패하면 뒤 단계는 실행되지 않는다. 실패하면 파일을 다시 받는다.
- 2026-11-15 kit의 압축본 sha256은 `2ded1cf471f8ea00eca451949946d406149e03f19c15d65f6553942d7a2cce70`이다.
- USB·네트워크로 복사한 `claude`에는 quarantine 속성이 붙는다. 설치기가 서명(팀 `Q6L2SF6YDW`, 식별자 `com.anthropic.claude-code`)을 직접 확인한 뒤 그 파일 하나에서만 속성을 지운다. `xattr -cr`이나 Gatekeeper 끄기는 하지 않는다([INSTALL-ISSUES.md 1.11](INSTALL-ISSUES.md#111-usb네트워크로-복사한-바이너리의-quarantine)).

## 4. 설치

### 4.1 먼저 dry-run

무엇이 바뀌는지만 보여 준다. 실제 설치와 같은 사전 검사(파일 존재, python import, env 파일 형식)를 한다.

```bash
./install-claude-code.sh --dry-run
```

```bash
./install-claude-code.sh --router-load --dry-run
```

### 4.2 설치 방식 고르기

| 상황 | 명령 |
|---|---|
| LM Studio만 쓰는 Mac | `./install-claude-code.sh` |
| Spark를 쓰는 Mac, 라우터까지 바로 시작 | `./install-claude-code.sh --router-load --spark-env=<키 파일>` |
| 라우터 파일만 두고 나중에 시작 | `./install-claude-code.sh --with-router` |
| 모델을 직접 지정 | `./install-claude-code.sh --model=<LM Studio 모델 id>` |

`--router-load`를 처음 실행하면 라우터 env에 Spark 주소(`http://spark.local:8000`, 다른 주소는 `--spark-url`)가 들어간다. 키는 `--spark-env`로 주지 않으면 비어 있다. 키가 없으면 라우터는 뜨지만 Spark를 다운으로 보고 `spark-large`를 로컬 모델로 보낸다. §5에서 env를 채우고 다시 띄우면 Spark로 간다.

통합 번들의 `install-all.sh`는 이 단계에 `--router-load`를 기본으로 넘긴다. LM Studio만 쓸 Mac은 `install-all.sh --no-router`로 설치한다.

### 4.3 옵션

옵션은 모두 `=` 형식이다.

| 옵션 | 뜻 | 기본값 |
|---|---|---|
| `--model=ID` | claude-lms가 쓸 LM Studio 모델 id | 기존 env 파일 → `~/llm-wiki/.env`의 `WIKI_INGEST_MODEL` → LM Studio 목록의 첫 LLM |
| `--context=N` | 모델을 올릴 최소 context | 65536 |
| `--lmstudio-url=URL` | LM Studio 서버 | `http://127.0.0.1:1234` |
| `--with-router` | llm-router 설치(router.py, spark-model, env 파일, LaunchAgent). 시작은 하지 않음 | |
| `--router-load` | `--with-router` + LaunchAgent를 바로 시작하고 `/health`를 기다림 | |
| `--spark-url=URL` | 라우터 env의 `SPARK_URLS`(URL 하나 또는 쉼표 목록). `SPARK_URL`은 첫 URL, `SPARK_SWITCH_URL`은 그 호스트의 8010. 빈 항목(끝 쉼표·겹쉼표)은 거부 | `http://spark.local:8000,http://spark.local:8001` |
| `--spark-env=FILE` | 키 파일에서 `SPARK_API_KEY`·`SPARK_SWITCH_TOKEN`(또는 `VLLM_API_KEY`·`SWITCH_TOKEN`)만 라우터 env로 옮김. 값은 출력하지 않음 | |
| `--no-skills` | hwpx·docx·xlsx·pptx skill을 설치하지 않음 | |
| `--no-path` | `~/.zshrc`에 PATH 블록을 넣지 않음 | |
| `--dry-run` | 바뀔 내용만 표시 | |

### 4.4 설치기가 하는 일

1. **서명 확인 → 바이너리 설치.** 같거나 더 새 claude가 이미 있으면 그대로 둔다.
2. **claude-lms와 설정 파일.** `~/.config/claude-lms/env`(600)에 `CLAUDE_LMS_MODEL`·`URL`·`CONTEXT`를 쓴다. 모델 id는 LM Studio `/v1/models`와 대조한다. LM Studio가 응답하는데 목록에 없으면 멈추고, 응답하지 않으면 경고만 내고 계속한다.
   - 기존 파일의 다른 `CLAUDE_LMS_*` 한 줄 설정(ROUTER, DISALLOWED_TOOLS 등)은 그대로 옮겨 적는다. **주석 줄은 옮기지 않는다.**
   - 여러 줄에 걸친 값이 있으면 줄 번호만 알려 주고 멈춘다(값은 출력하지 않는다).
   - `--with-router`이고 기존 파일에 `CLAUDE_LMS_ROUTER`가 없으면 `CLAUDE_LMS_ROUTER='http://127.0.0.1:<라우터 포트>'`를 더한다. 포트는 라우터 env의 `LLM_ROUTER_PORT`(기본 1240)다.
   - `--with-router`이고 기존 파일에 `CLAUDE_LMS_PICKER`가 없으면 `CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct'`를 더한다(VS Code 모델 선택 목록의 Opus·Sonnet·Haiku·Fable 행).
3. **skill.** `~/.claude/skills/<이름>`에 설치하고 각 skill을 시험 실행해 본다([CLAUDE-LMS-MANUAL.md §2.3](CLAUDE-LMS-MANUAL.md#23-hwpx-skill-설치)).
4. **llm-router** (`--with-router`일 때만). kit의 `llm-router/install-llm-router.sh`를 같은 python으로 실행한다.
   - `~/.guardian-llm/llm-router/router.py`, `~/.local/bin/spark-model`, LaunchAgent `dev.guardian.llm-router`(로그 `~/.guardian-llm/logs`).
   - `~/.config/llm-router/env`(600)는 **없을 때만** `env.example`로 만든다. 새로 만든 경우에만 `LOCAL_URL`·`LOCAL_MODEL`을 이번 설치의 LM Studio 주소·모델로 바꾸고 `SPARK_URL`·`SPARK_URLS`·`SPARK_SWITCH_URL`을 켠다. 이미 있던 파일은 `--spark-url`·`--spark-env`로 준 키만 바꾸고, 둘 다 없으면 건드리지 않는다.
   - `--router-load`면 env를 정리한 뒤에 LaunchAgent를 시작한다.
5. **PATH.** `~/.local/bin`이 없으면 `~/.zshrc`에 표시 블록을 한 번 넣는다. 새 터미널부터 적용된다([INSTALL-ISSUES.md 1.12](INSTALL-ISSUES.md#112-localbin이-path에-없음)).

## 5. 라우터 env 설정 (`~/.config/llm-router/env`)

Spark를 쓰려면 이 파일을 채워야 한다. 파일에는 Spark 키가 들어가므로 권한 600을 유지하고, **값을 화면·로그·채팅에 찍지 않는다.**

| 키 | 넣을 것 |
|---|---|
| `SPARK_URLS` | `http://spark.local:8000,http://spark.local:8001` (상주 페어) |
| `SPARK_URL` | 단일 모드 Spark라면 이 한 줄로 충분하다. `SPARK_URLS`가 있으면 그쪽이 이긴다 |
| `SPARK_SWITCH_URL` | `http://spark.local:8010` (spark-switch 컨트롤러) |
| `SPARK_API_KEY` | Spark `~/vllm-work/.vllm-env`의 vLLM 키 |
| `SPARK_SWITCH_TOKEN` | Spark `~/spark-switch/env`의 `SWITCH_TOKEN` |
| `LOCAL_URL`, `LOCAL_MODEL` | 폴백 LM Studio. 새로 만든 파일이면 설치기가 채워 둔다 |

- 나머지 키(`SPARK_PREFER`, `HEALTH_*`, `UPSTREAM_*` 등)는 `env.example`의 기본값을 쓴다. 뜻은 [guardian/llm-router/README.md](../guardian/llm-router/README.md)를 본다.
- 설치할 때 `--spark-env=FILE`을 주면 위 두 키를 설치기가 옮긴다. Spark의 두 파일을 이어 붙인 파일을 그대로 줘도 된다.
- 토큰은 원본 파일에서 대상 파일로 바로 옮긴다. `cat`·`echo`로 값을 출력하거나 명령줄 인자로 넘기지 않는다([LLM-ROUTER.md §2](LLM-ROUTER.md#2-설치-순서) 2단계).
- 주소를 정하는 원칙(mDNS 이름 사용, `/etc/hosts`를 쓰지 않는 이유, IPv4 강제)은 [LLM-ROUTER.md §2.1](LLM-ROUTER.md#21-spark-주소)에 있다.

고친 뒤 라우터를 다시 띄운다.

```bash
launchctl kickstart -k gui/$(id -u)/dev.guardian.llm-router
```

`--with-router`로 설치해 아직 시작하지 않았다면 다음 명령으로 시작한다(또는 `--router-load`로 다시 실행).

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.guardian.llm-router.plist
```

## 6. claude-lms env 설정 (`~/.config/claude-lms/env`)

환경 변수로 같은 이름을 주면 파일보다 우선한다. 한 키에 한 줄, 작은따옴표 값으로 쓴다.

| 키 | 뜻 | 기본값 | 권장 |
|---|---|---|---|
| `CLAUDE_LMS_MODEL` | LM Studio 모델 id | 설치기가 씀 | |
| `CLAUDE_LMS_URL` | LM Studio 서버 | `http://127.0.0.1:1234` | |
| `CLAUDE_LMS_CONTEXT` | 모델을 올릴 최소 context | 65536 | 65536 유지 |
| `CLAUDE_LMS_ROUTER` | llm-router 주소. 비우면 LM Studio에 바로 붙음 | 없음 | Spark를 쓰면 `http://127.0.0.1:1240` |
| `CLAUDE_LMS_LARGE` | 메인·sonnet 모델 별칭 (라우터 모드) | `spark-large` | |
| `CLAUDE_LMS_FAST` | haiku·백그라운드 호출 별칭 (라우터 모드) | `local-fast` | |
| `CLAUDE_LMS_SUBAGENT` | 서브에이전트 별칭 (라우터 모드) | `spark-large` | |
| `CLAUDE_LMS_PICKER` | VS Code 확장의 모델 선택 목록에 넣을 모델 id 1~4개(공백 구분, 순서대로 Opus·Sonnet·Haiku·Fable 행). VS Code 애드온 설치 때만 읽음 (라우터 모드) | 없음 | `install-vscode.sh --pick-models`가 알려 주는 값. [VSCODE-ADDON.md §4.1](VSCODE-ADDON.md#41-모델-선택-목록-고르기---pick-models) |
| `CLAUDE_LMS_MAX_OUTPUT` | Claude Code 출력 토큰 상한 | 16384 | 16384 유지 |
| `CLAUDE_LMS_DISALLOWED_TOOLS` | 모델에 보여 주지 않을 도구(쉼표 구분) | 없음(전부) | `'Workflow,ScheduleWakeup,ReportFindings,ListAgents'` |
| `CLAUDE_LMS_SKILL_GUARD` | `0`이면 skill-guard hook을 끔 | 켬 | 켠 채로 |

**`CLAUDE_LMS_MAX_OUTPUT`을 16384로 두는 이유.** vLLM은 입력 + `max_tokens`가 로드된 창(65536)을 넘으면 400을 낸다. Claude Code 기본값 32000이면 입력 33,536 tok부터 400이 나고, 16384면 49,152 tok까지 괜찮다. 기본 프롬프트만 약 11k tok이다(SPARK-SETTINGS-MAP.md).

**`CLAUDE_LMS_DISALLOWED_TOOLS` 권장값(deny4).** 쓰지 않는 도구 정의 4개를 빼서 첫 요청 입력이 10,952 → 7,537 tok(−31%)으로 준다. 시스템 프롬프트·hook·핵심 도구는 그대로다. 설치기는 이 값을 기본으로 넣지 않으므로 직접 한 줄 추가한다. 운영 Mac은 2026-11-15부터 이 값을 쓴다. 근거와 실제 프롬프트는 claude-code-prompt/README.md와 SPARK-USAGE-REVIEW-20261115.md §8·§9에 있다.

```bash
CLAUDE_LMS_DISALLOWED_TOOLS='Workflow,ScheduleWakeup,ReportFindings,ListAgents'
```

- `--bare`는 시스템 프롬프트를 두 줄로 줄이고 skill-guard hook까지 꺼서 쓰지 않는다.
- 재설치하면 `CLAUDE_LMS_*` 줄은 남지만 주석은 사라진다. 메모가 필요하면 이 문서나 운영 기록에 남긴다.
- `CLAUDE_LMS_TOKEN`도 쓸 수 있지만 LM Studio·라우터 모두 기본값이면 따로 두지 않는다. 값을 넣었다면 출력하지 않는다.

## 7. macOS 로컬 네트워크 권한 (macOS 15 이상)

LaunchAgent로 뜬 라우터는 로컬 네트워크 권한이 있어야 Spark(LAN)에 닿는다. 권한이 없으면 `/health`의 `spark.last_error`에 `ConnectError`가 남고 `spark-large`는 `local (spark-down)`으로 간다.

- 허용 창이 뜨거나 *시스템 설정 → 개인정보 보호 및 보안 → 로컬 네트워크*에 `python3.12`가 보이면 켠다. **화면 앞에서 직접 한다.**
- ssh로 실행한 프로세스는 이 제한을 받지 않는다. 확인은 ssh 셸의 `curl`로 Spark를 부르는 것이 아니라 라우터 `/health`로 한다.
- `~/.guardian-llm/python/bin/python3.12`를 다시 서명하거나 바꾸면 권한을 다시 확인한다.

자세한 내용은 [LLM-ROUTER.md §2](LLM-ROUTER.md#2-설치-순서) 6단계에 있다.

## 8. 설치 후 확인

새 터미널을 열고 차례로 실행한다.

```bash
claude --version
```

```bash
curl -s http://127.0.0.1:1240/health
```

```bash
spark-model status
```

```bash
claude-lms -p "hi"
```

```bash
claude-lms mcp list
```

| 명령 | 정상 |
|---|---|
| `claude --version` | kit의 `VERSION`과 같거나 더 새 버전 |
| `/health` (라우터 설치 시) | `spark`가 up이고 `last_error`가 비어 있음. `local`도 up |
| `spark-model status` (라우터 설치 시) | Spark가 올린 프로필(기본 페어 `qwen3-instruct` + `qwen3-coder`) |
| `claude-lms -p "hi"` | 짧은 인사 응답. 라우터 모드면 Spark가 답함 |
| `claude-lms mcp list` | 오류 없이 끝남(등록한 MCP 서버가 없으면 빈 목록) |

처음 대화형으로 `claude-lms`를 실행하면 폴더 신뢰 질문이 나온다. 기본 선택이 "No, exit"이니 확인하고 고른다([INSTALL-ISSUES.md 1.6](INSTALL-ISSUES.md#16-첫-실행-화면-폴더-신뢰-질문의-기본-선택이-no-exit)).

## 9. 다시 설치·업그레이드

- 새 kit을 받아 §3~§4를 그대로 반복한다. 기존 claude-lms env의 `CLAUDE_LMS_*` 값과 라우터 env는 보존된다.
- 바꾸기 전에 설정을 백업해 둔다.

```bash
cp -p ~/.config/claude-lms/env ~/.config/claude-lms/env.bak-$(date +%Y%m%d-%H%M%S)
```

- 모델만 바꾸려면 `./install-claude-code.sh --model=<id>`를 다시 실행하거나 env 파일의 `CLAUDE_LMS_MODEL`을 고친다.
- Claude Code를 올린 뒤에는 실제 프롬프트가 달라질 수 있다. 다시 기록하는 방법은 claude-code-prompt/README.md의 "다시 기록하기"에 있다.

## 10. 문제가 생기면

| 증상 | 볼 곳 |
|---|---|
| `claude-lms: …`로 시작하는 오류(모델 없음, LM Studio 응답 없음, context 부족) | [CLAUDE-LMS-MANUAL.md §3.3](CLAUDE-LMS-MANUAL.md#33-문제-해결) |
| 설치 중 오류, quarantine, PATH, 기존 claude 충돌, 외부 통신 | [INSTALL-ISSUES.md 1부](INSTALL-ISSUES.md#1부-claude-code--lm-studio) |
| `spark-large`가 로컬로만 감, Spark 다운, 교체 실패 | [LLM-ROUTER.md §4](LLM-ROUTER.md#4-장애-시-동작) |
| 라우터 로그 | `~/.guardian-llm/logs/` |
| skill-guard가 막은 이유 | [CLAUDE-LMS-MANUAL.md §3.4](CLAUDE-LMS-MANUAL.md#34-skill-guard-hook) |
| 400 오류(입력이 창을 넘음), 출력 상한 | SPARK-SETTINGS-MAP.md, SPARK-USAGE-REVIEW-20261115.md |
| VS Code 확장에서 쓰기 | [CLAUDE-LMS-MANUAL.md §3.5](CLAUDE-LMS-MANUAL.md#35-vs-code에서-쓰기), [LLM-ROUTER.md §3.3](LLM-ROUTER.md#33-vs-code-확장) |
| VS Code가 없는 현장 Mac에 VS Code·Foam·확장 설치 | [VSCODE-ADDON.md](VSCODE-ADDON.md) (별도 add-on) |
| 현장 Mac에서 HWP·HWPX 열어 보기(오프라인 뷰어 HOP) | [guardian/hop-viewer/README.md](../guardian/hop-viewer/README.md) (별도 꾸러미) |

## 11. kit 만들기 (보내는 쪽)

kit을 만드는 Mac에서 실행한다. 결과물은 `dist/claude-code-kit/`에 버전·UTC 시각이 붙은 이름으로 쌓인다.

```bash
guardian/pack-claude-code.sh
```

- 서명, 휠 sha256, 비밀 파일·심볼릭 링크 부재를 검사하고, 다시 풀어 `SHA256SUMS`가 맞을 때만 완성한다.
- 옵션(`--claude-code=`, `--out=`, `--name=`, `--no-tar`)과 검사 내용은 [CLAUDE-LMS-MANUAL.md §2.2](CLAUDE-LMS-MANUAL.md#22-claude-code만-따로-설치재설정)에 있다.
- `guardian/claude-lms`나 설치기를 바꿨다면 kit을 다시 만들고 SPARK-SETTINGS-MAP.md의 해시를 고친다.
