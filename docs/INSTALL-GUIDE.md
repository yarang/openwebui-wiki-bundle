# 통합 번들 설치 가이드 (macOS arm64)

> 대상: 인터넷 없는 현장 Mac 에 **통합 번들**(`llm-wiki-bundle-<시각>-macos-arm64`)을 처음 깔거나 새 버전으로
> 바꾸는 담당자.
> 기준: `install-llm-wiki.sh` → `install-all.sh` 1~7단계 (번들 MANIFEST: wiki_mcp 0.2.6, Claude Code 2.1.328,
> VS Code 1.146.0, Foam 0.48.0, HOP 0.5.4, Open WebUI 0.12.3).
> 설치 뒤 매일 쓰는 점검·재시작·백업은 [OPERATIONS.md](OPERATIONS.md), 번들 안의 폴더 구조는
> training/BUNDLE-STRUCTURE.md, 지난 설치에서 겪은 문제 기록은
> [INSTALL-ISSUES.md](INSTALL-ISSUES.md) 를 봅니다.
> 단독 openwebui-wiki 번들(`openwebui-wiki-bundle-*`)은 이 문서가 아니라 저장소 루트의 `INSTALL.md` 를 따릅니다.

## 1. 준비물

| 항목 | 내용 |
|---|---|
| Mac | Apple Silicon(arm64). 인텔 Mac 은 지원하지 않음 |
| 계정 | 평소 쓰는 로그인 계정. 관리자 권한이 없어도 됨(sudo 를 쓰지 않음) |
| 여유 공간 | 아카이브 크기 × 2.5 + 2 GB 이상 (설치 스크립트가 먼저 확인하고 모자라면 멈춤) |
| 화면 | LM Studio 첫 실행과 Gatekeeper 확인 창을 눌러야 하므로 **GUI 로그인 세션**에서 실행 |
| 네트워크 | 필요 없음. 설치 스크립트는 아무것도 내려받지 않음 |

현장으로 옮기는 파일은 세 개입니다. 한 폴더(예: `~/bundles`)에 같이 둡니다.

| 파일 | 역할 |
|---|---|
| `llm-wiki-bundle-<시각>-macos-arm64.tar.xz` | 번들 본체 (약 8 GB) |
| `llm-wiki-bundle-<시각>-macos-arm64.tar.xz.sha256` | 무결성 확인값 |
| `install-llm-wiki.sh` | 한 번에 설치하는 스크립트 |

> USB 로 옮겼다면 복사가 끝까지 됐는지 파일 크기부터 봅니다. sha256 이 맞지 않으면 설치가 시작되지 않습니다.

## 2. 설치 순서

### 2-1. 미리보기 (권장)

```bash
cd ~/bundles
bash install-llm-wiki.sh --dry-run
```

sha256 확인 → 여유 공간 확인 → 압축 풀기까지는 실제로 하고, 그 뒤 `install-all.sh` 가 할 일을 출력만 합니다.
압축 풀기는 `/usr/bin/tar` 한 코어로 돌아 7 GB 기준 5분 안팎 걸립니다. 이미 풀린 폴더가 있으면 다시 풀지 않고
씁니다.

### 2-2. 설치

```bash
bash install-llm-wiki.sh
```

스크립트가 하는 일:

1. 아카이브 sha256 확인
2. 여유 공간 확인 (아카이브 × 2.5 + 2 GB)
3. 아카이브 옆에 압축 풀기
4. 번들의 `install-all.sh` 실행 (아래 1~7단계)
5. LM Studio 첫 실행 — 앱이 설정 파일을 이때 처음 씁니다. 화면에 확인 창이 뜨면 **열기**를 누릅니다
6. wiki 단계(`wiki-layer/install-wiki.sh`) 한 번 더 — LM Studio 서버가 앱과 함께 켜지도록 설정

LM Studio 를 이미 한 번 띄웠고 `:1234` 가 응답하는 Mac 이면 5·6은 건너뜁니다.
스크립트는 아무것도 지우지 않고, 바꿀 앱은 `*.old-<버전>.app` 으로 옮겨 둡니다.

### 2-3. install-all.sh 7단계

| 단계 | 스크립트 | 하는 일 | 생략 옵션 |
|---|---|---|---|
| 1/7 | `install.sh` (guardian) | LM Studio 런타임·모델, Python 3.12, Open WebUI (`~/.guardian-llm`). 서비스는 아직 켜지 않음 | — |
| 2/7 | 앱 단계 | 공식 dmg 에서 `LM Studio.app` 복사 (`/Applications`, 쓸 수 없으면 `~/Applications`) | `--no-app` |
| 3/7 | `install-wiki.sh` | wiki-mcp·mcpo·watch 서비스 추가, Open WebUI 에 위키 도구 연결, 서비스 재시작 (`~/llm-wiki`) | — |
| 4/7 | `install-claude-code.sh` | `claude`, `claude-lms`, 스킬을 `~/.local/bin` 에 설치. llm-router(127.0.0.1:1240)를 설치·시작하고 claude-lms 를 라우터 모드로 설정 | `--no-claude-code` (라우터만 빼려면 `--no-router`) |
| 5/7 | `install-wiki-mcp.sh` | 공용 wiki-mcp HTTP 서버(127.0.0.1:8765) 하나로 모으고 mcpo 를 중계로 전환, Claude Code 에 `wiki` 등록 | `--no-wiki-mcp-http` |
| 6/7 | `install-vscode.sh` | VS Code, Foam·Claude Code 확장, 오프라인 설정, 위키 작업 폴더 설정 | `--no-vscode` |
| 7/7 | `install-hop.sh` | HOP 뷰어 설치, `.hwp/.hwpx` 기본 앱 등록 | `--no-hop` |

> 5단계는 4단계가 깐 `claude` CLI 가 있어야 하고, 6단계는 4단계가 쓴 `~/.config/claude-lms/env` 를 읽습니다.
> 순서를 바꾸지 마세요. 7단계는 다른 단계와 독립입니다.

#### 처음부터 라우터 모드

4단계는 기본으로 llm-router 를 설치하고 시작합니다. 그래서 처음 설치한 Mac 에서도 claude-lms 와 VS Code 확장이 같은 값으로 시작합니다.

| 값 | 라우터 모드 (기본) | `--no-router` |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:1240` (`CLAUDE_LMS_ROUTER`) | `http://127.0.0.1:1234` |
| Opus·Sonnet·Subagent | `spark-large` | `CLAUDE_LMS_MODEL` |
| Haiku·`SMALL_FAST` | `local-fast` | `CLAUDE_LMS_MODEL` |
| VS Code 모델 선택 목록 | `CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct'`. 순서대로 Opus·Sonnet·Haiku·Fable 행 | 모든 행이 `CLAUDE_LMS_MODEL` |

- 라우터 env(`~/.config/llm-router/env`, 600)는 처음 만들 때 `SPARK_URLS=http://spark.local:8000,http://spark.local:8001`(Spark 의 vLLM 두 개), `SPARK_URL=http://spark.local:8000`, `SPARK_SWITCH_URL=http://spark.local:8010` 이 들어갑니다. 다른 주소는 `--spark-url=URL` 로 줍니다. 쉼표로 여러 개를 줄 수 있고, 첫 주소가 `SPARK_URL` 과 스위치 주소의 기준이 됩니다.
- Spark 키는 번들에 들어 있지 않습니다. 설치할 때 `--spark-env=FILE` 로 줍니다. Spark 의 `~/vllm-work/.vllm-env` 와 `~/spark-switch/env` 를 이어 붙인 파일을 그대로 써도 됩니다. 키 값은 화면에 찍히지 않습니다. 스크립트는 키 파일을 읽기만 하므로, 파일은 600 으로 두고 설치가 끝나면 직접 지웁니다.

  ```bash
  bash install-llm-wiki.sh --spark-env="$HOME/spark-keys.env"
  ```

- 키가 없으면 `spark-large` 는 local(LM Studio)로 넘어가 동작합니다. Spark 가 없는 Mac 도 그대로 씁니다.
- 이미 있는 라우터 env 와 `CLAUDE_LMS_PICKER` 는 그대로 둡니다. 다시 설치할 때는 `--spark-url`·`--spark-env` 로 준 키만 바뀝니다.
- VS Code 설정 파일(settings.json)에 이미 내용이 있으면 고치지 않고 옆 파일(`settings.vscode-addon.jsonc`)에 씁니다. 기존 설정이 LM Studio 를 직접 가리키면 경고하니, 옆 파일의 `claudeCode.environmentVariables` 로 바꿔 붙입니다.

## 3. 옵션

`install-llm-wiki.sh` 자체 옵션 외의 옵션은 모두 `install-all.sh` 로 넘어갑니다. 값은 `=` 로 붙여 씁니다.

| 대상 | 옵션 | 동작 |
|---|---|---|
| 설치기 | `--archive=PATH` | 설치할 아카이브 (기본: 스크립트 옆의 `llm-wiki-bundle-*.tar.xz`) |
| 설치기 | `--dest=DIR` | 압축 풀 위치 (기본: 아카이브 폴더) |
| 설치기 | `--launch-timeout=S` | LM Studio 첫 실행을 기다릴 시간, 초 (기본 180) |
| 전체 | `--dry-run` / `--no-start` | 미리보기 / 설치만 하고 서비스는 켜지 않음 |
| 전체 | `--prefix=DIR` | guardian 위치 (기본 `~/.guardian-llm`) |
| 전체 | `--embedding-model=M` | 임베딩 모델 (기본 `text-embedding-bge-m3`) |
| 앱 | `--no-app` / `--upgrade-app` | LM Studio 앱 생략 / 더 오래된 앱을 새 버전으로 교체 (LM Studio 를 닫은 상태에서. 설치 중에 1단계가 띄운 LM Studio 서비스는 설치기가 내림) |
| guardian | `--no-models` `--skip-verify` `--port=N` `--lmstudio-url=URL` | 모델 생략, 무결성 검사 생략(아카이브 sha256 포함), Open WebUI 포트, LM Studio 주소 |
| wiki | `--wiki-home=DIR` | 위키 위치 (기본 `~/llm-wiki`) |
| wiki | `--mcpo-port=N` | mcpo 포트 (기본 8766) |
| wiki | `--webui-host=H` | Open WebUI 바인드 주소 (기본 127.0.0.1, `0.0.0.0` 이면 같은 망에 공개) |
| wiki | `--migrate-from=OLD_BUNDLE` | 예전 단독 번들의 데이터 복사 (§6) |
| claude | `--no-claude-code` `--no-skills` | Claude Code 생략 / 스킬 생략 |
| claude | `--no-router` `--with-router` `--router-load` | llm-router 를 빼고 LM Studio 직접 모드 / 설치만 하고 시작은 안 함 / 설치하고 바로 시작 (기본) |
| claude | `--spark-url=URL` | Spark vLLM 주소 (기본 `http://spark.local:8000`, 스위치는 같은 호스트의 8010) |
| claude | `--spark-env=FILE` | Spark 키 파일. `SPARK_API_KEY` `SPARK_SWITCH_TOKEN`(또는 Spark 쪽 이름 `VLLM_API_KEY` `SWITCH_TOKEN`)만 라우터 env 로 옮김 |
| wiki-mcp | `--no-wiki-mcp-http` `--wiki-mcp-port=N` | 공용 서버 생략 / 포트 (기본 8765) |
| vscode | `--no-vscode` `--no-vscode-app` `--vscode-app-dir=DIR` | 단계 생략 / 앱은 두고 확장·설정만 / 앱 위치 |
| hop | `--no-hop` `--no-hop-register` `--hop-app-dir=DIR` | 단계 생략 / 기본 앱 등록 생략 / 앱 위치 |

모르는 옵션을 주면 바로 멈춥니다(종료 코드 2). Open WebUI 는 번들의 중심이라 끄는 옵션이 없습니다.

## 4. 설치 뒤 확인

터미널에서 아래가 모두 통과하면 설치가 끝난 것입니다.

```bash
curl -sf http://127.0.0.1:8080/health && echo webui-ok
curl -sf -o /dev/null http://127.0.0.1:8766/openapi.json && echo mcpo-ok
curl -sf -m 3 http://127.0.0.1:1234/v1/models | head -c 300; echo
curl -sf -m 3 http://127.0.0.1:1240/health; echo
claude mcp get wiki
```

| 확인 | 기대 결과 |
|---|---|
| Open WebUI | 브라우저에서 `http://127.0.0.1:8080` → 첫 화면에서 관리자 계정 만들기 |
| 위키 도구 | 채팅 입력창의 도구 목록에 위키 도구가 보임 |
| LM Studio | `/v1/models` 에 채팅 모델과 임베딩 모델이 보임 |
| llm-router | `:1240/health` 가 응답. Spark 가 없거나 꺼져 있어도 local(LM Studio) 은 살아 있음 |
| Claude Code | `claude mcp get wiki` 가 연결됨으로 표시, `claude-lms` 가 `router http://127.0.0.1:1240` 줄을 찍고 응답 |
| VS Code | `~/llm-wiki/wiki` 를 열고 "Do you trust the authors?" 에 **Trust** |
| HOP | `.hwp` 파일을 두 번 클릭하면 HOP 으로 열림 |

자세한 상태 점검 명령은 [OPERATIONS.md §3](OPERATIONS.md#3-매일-점검) 에 있습니다.

## 5. 문제 해결

| 증상 | 원인 | 조치 |
|---|---|---|
| 설치기가 종료 코드 3으로 멈춤 | LM Studio 첫 실행이 `--launch-timeout` 안에 끝나지 않음. 대개 Gatekeeper 확인 창이 기다리는 중 | 확인 창에서 **열기** → `cd "<번들 폴더>/wiki-layer" && ./install-wiki.sh` |
| `--no-start` 로 설치함 | 서비스가 꺼진 상태 | 설치기가 끝에 출력한 대로 LM Studio 를 한 번 열고 `wiki-layer/install-wiki.sh` 를 다시 실행 |
| 앱이 `~/Applications` 에 들어감 | `/Applications` 에 쓸 권한이 없는 계정 | 정상 동작. 관리자가 이미 깐 VS Code·HOP 이 `/Applications` 에 있으면 그 앱을 그대로 씀 |
| 위키 검색이 키워드로만 됨 | LM Studio 서버(`:1234`)가 아직 꺼져 있어 임베딩을 못 만듦 (`--no-app` 설치 직후 흔함) | LM Studio 를 켜고 서버를 시작. 이후 watch 가 임베딩을 채움. 검색은 그동안 BM25 로 동작 |
| `lms` 명령이 키 파일 오류 | `~/.lmstudio/.internal/lms-key-2` 는 LM Studio 를 GUI 로 처음 띄울 때 생김 | 그 계정으로 화면에 로그인해 LM Studio 를 한 번 실행 |
| 로그인 직후 Open WebUI 가 응답 없음 | 같은 Mac 의 다른 계정이 8080 포트를 쥐고 있음 (포트는 Mac 전체 공용) | 다른 계정의 서비스를 멈춘 뒤 `launchctl kickstart -k "gui/$(id -u)/dev.guardian.openwebui"` |
| VS Code 의 Claude 가 응답 없음 | 확장은 라우터(`:1240`)만 봄. claude-lms 와 달리 라우터가 꺼져 있을 때 LM Studio 로 넘어가지 않음 | `launchctl kickstart -k "gui/$(id -u)/dev.guardian.llm-router"`. 라우터를 쓰지 않을 Mac 은 `--no-router` 로 설치 |
| `spark-large` 가 늘 local 로 감 | 라우터 env 의 `SPARK_API_KEY` 가 비었거나 Spark 가 꺼짐 | `--spark-env=FILE` 로 다시 설치하거나 `~/.config/llm-router/env`(600) 를 고친 뒤 라우터 재시작 |
| `--upgrade-app` 이 "LM Studio is running: close it first" 로 멈춤 | 설치 시작 전부터 LM Studio 가 켜져 있음. 메뉴 막대에 남는 앱이라 창을 닫아도 계속 돈다 | 메뉴 막대 LM Studio 아이콘 → Quit 후 다시 실행. 1단계가 `lms runtime select` 로 깨운 LM Studio(`--run-as-service`)는 설치기가 알아서 내리므로 이 오류의 원인이 아님 |
| "LM Studio ... has no model gemma-4-e4b-it-mlx" | LM Studio 카탈로그로 gemma 를 받은 Mac 은 같은 모델이 `google/gemma-4-e4b` 로 보임 (`~/.lmstudio/hub/models/google/gemma-4-e4b/`) | 지금 설치기는 두 id 를 같은 모델로 보고 이 Mac 의 LM Studio 가 나열하는 쪽을 씀. 예전 번들이라면 `~/.config/claude-lms/env` 에 `CLAUDE_LMS_MODEL='google/gemma-4-e4b'` 를 미리 쓰고 다시 실행. 허브 폴더를 치우면 LM Studio 0.4.26 이 모델을 아예 못 찾으니 지우지 말 것 |
| sha256 불일치 | 복사 도중 잘림·손상 | 원본에서 다시 복사. `--skip-verify` 로 넘기지 말 것 |
| 여유 공간 부족 | 아카이브 × 2.5 + 2 GB 미만 | 공간 확보 후 다시 실행 (이미 풀린 부분은 재사용) |

Claude Code 와 LM Studio 조합에서 생기는 문제(context 크기, 첫 실행 질문, quarantine, PATH)는
[INSTALL-ISSUES.md 1부](INSTALL-ISSUES.md#1부-claude-code--lm-studio) 를 봅니다.

## 6. 업그레이드와 이전

| 상황 | 방법 |
|---|---|
| 새 통합 번들로 교체 | 새 세 파일을 다른 폴더에 두고 `bash install-llm-wiki.sh`. 위키(`~/llm-wiki/wiki`)와 Open WebUI DB 는 그대로 둔 채 실행 파일·서비스만 바뀝니다. 먼저 [OPERATIONS.md §6](OPERATIONS.md#6-백업과-복원) 대로 백업 |
| LM Studio 앱도 새 버전으로 | LM Studio 를 닫고 `--upgrade-app` 추가. 예전 앱은 이름을 바꿔 남겨 둠 |
| 예전 단독 openwebui-wiki 번들에서 이전 | 예전 번들의 프로세스를 모두 멈춘 뒤 `bash install-llm-wiki.sh --migrate-from="<예전 번들 폴더>"`. Open WebUI 데이터·비밀키·위키·wiki-data·raw 를 **복사**합니다(원본은 그대로) |
| 앱 하나만 추가·교체 | 번들 안의 `vscode-addon/`, `hop-viewer/`, `wiki-mcp-kit/` 폴더를 따로 옮겨 각 README 대로 설치 |

## 7. 선택 키트

| 키트 | 폴더 | 언제 |
|---|---|---|
| VS Code 애드온 | `vscode-addon/` | 이미 설치된 Mac 에 위키 편집기를 더할 때 |
| HOP 뷰어 | `hop-viewer/` | 한글 문서 뷰어만 더하거나 바꿀 때 |
| 공용 wiki-mcp | `wiki-mcp-kit/` | 5단계를 생략했거나 다시 걸 때 |
| llm-router | `claude-code/` 의 `--with-router` / `--router-load` | 키트를 따로 설치할 때 (`install-all.sh` 는 기본으로 설치하고 시작) |

각 키트의 되돌리기 방법은 [OPERATIONS.md §10](OPERATIONS.md#10-되돌리기) 에 모아 두었습니다.
