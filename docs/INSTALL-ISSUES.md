# 설치 중 발생한 문제와 해결

오프라인 번들(guardian 기반 merged bundle)을 깨끗한 Mac(test-mac)과 운영 Mac(prod-mac)에 설치하면서
실제로 겪은 문제를 정리합니다. 각 항목은 **증상 → 원인 → 해결 → 확인 방법** 순서입니다.

- 1부: Claude Code를 번들에 넣고 LM Studio 로컬 모델로 돌리면서 생긴 문제 (2026-11-02, test-mac)
- 2부: 그 이전 번들 설치(LM Studio 앱, wiki-mcp, 설치 스크립트)에서 생긴 문제 (2026-10-24 ~ 10-27)
- 3부: 남은 과제

관련 파일: `guardian/install-claude-code.sh`, `guardian/claude-lms`, `guardian/install-all.sh`,
`guardian/build-merged-bundle.sh`, `guardian/install-wiki.sh`

---

## 1부. Claude Code + LM Studio

### 구성 요약

```text
claude-lms (래퍼)
├── ~/.config/claude-lms/env 읽기 (모델 id, LM Studio URL, 최소 context)
├── lms ps --json 으로 로드 상태 확인 → 필요하면 lms load --context-length N
├── ANTHROPIC_BASE_URL=http://127.0.0.1:1234, 모든 모델 이름 → 같은 로컬 모델
└── exec ~/.local/bin/claude (→ ~/.local/share/claude/versions/<버전>)
```

### 1.1 JIT 로드 시 context가 4096/8192로 잡혀 응답이 엉망이 됨

- **증상**: `claude -p` 첫 호출에서 모델이 질문과 무관한 답을 하거나 도구 호출 형식이 깨짐.
- **원인**: Claude Code의 시스템 프롬프트와 도구 정의만으로 입력이 약 **11.3k 토큰**입니다. LM Studio는
  요청이 들어올 때 모델을 JIT 로드하는데, 이때 전역 기본 context(test-mac 8192, prod-mac 4096)를 씁니다.
  프롬프트 앞부분이 잘린 채로 모델이 답합니다.
- **해결**: `claude-lms`가 실행 전에 `lms ps --json`으로 로드 상태를 보고, 로드돼 있지 않으면
  `lms load <모델> --context-length <N> --identifier <모델> -y`로 직접 로드합니다. TTL은 주지 않습니다
  (유휴 언로드 후 다시 JIT로 돌아오면 기본 context로 되돌아가기 때문).
- **확인**: `~/.lmstudio/bin/lms ps` 에서 해당 모델의 CONTEXT 값이 설정값 이상인지 봅니다.

### 1.2 이미 작은 context로 로드돼 있을 때 다시 로드하면 다른 요청이 끊김

- **증상**: Open WebUI 채팅이나 wiki ingest가 먼저 JIT로 모델을 작게 로드해 두면 Claude Code에 context가
  모자랍니다. 그렇다고 바로 unload/load 하면 그 모델이 처리 중이던 채팅·ingest가 끊깁니다.
- **원인**: Open WebUI, wiki, Claude Code가 **같은 모델 id, 같은 인스턴스**를 공유합니다.
- **해결**: `claude-lms`가 터미널(tty)에서 실행되면 `Reload it now? ... [y/N]`로 묻고, 비대화형
  (`-p`를 스크립트에서 실행 등)이면 다시 로드하는 명령을 보여 주고 종료합니다. 묻지 않고 끊지 않습니다.
- **확인**: 8192로 로드한 상태에서 비대화형 실행 → 종료 코드 1과 reload 명령 출력 (test-mac에서 확인).

### 1.3 `CLAUDE_CODE_AUTO_COMPACT_WINDOW=32768`이 무시됨 (100k 하한)

- **증상**: 시작 시 경고 — 설정값이 32,768 토큰으로 읽히지만 100k 최소값으로 처리한다는 내용.
  실제로는 32k 창에서 100k까지 대화가 커질 수 있다고 보고 자동 압축(auto-compact)을 늦게 합니다.
- **원인**: Claude Code는 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`에 100k 하한을 둡니다.
- **해결**: 대신 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`에 **실제로 로드된 context 값**을 넣습니다. Claude Code가
  모르는 모델(로컬 모델)이면 이 값을 모델의 창 크기로 쓰고, 자동 압축 기준은
  `min(모델 창, 설정된 압축 창)`이라 함께 내려갑니다.
- **확인**: 수정 전 세션 로그에는 경고(⚠)가 1건, 수정 후에는 0건.

### 1.4 "알 수 없는 모델" 안내와 200k 창 가정

- **증상**: 로컬 모델 id(`google/gemma-4-e4b` 등)를 쓰면 Claude Code가 모델을 모른다는 안내를 띄우고 창을
  200k로 가정합니다.
- **해결**: 1.3과 같이 `CLAUDE_CODE_MAX_CONTEXT_TOKENS`를 설정합니다(안내 문구 자체가 이 변수를 쓰라고
  권합니다). 대화형 화면의 경고는 이것으로 사라졌습니다.
- **남는 것**: `-p`(print) 모드에서는 세션마다 한 번 다음 줄이 **stderr**로 나옵니다.

  ```text
  [claude-code:unrecognized_model] {"model":"gemma-4-e4b-it-mlx","query_source":"sdk"}
  ```

  stdout과 `--output-format json` 결과에는 섞이지 않으므로 스크립트에서 결과를 읽는 데 지장이 없습니다
  (2026-11-02 test-mac 확인). 보기 싫으면 `2>/dev/null`. JSON 결과의 `total_cost_usd`도 Anthropic 요금표로 계산한
  표시값일 뿐 실제 청구는 없습니다.

### 1.5 32k 창에서는 작업 여유가 약 10k 토큰뿐, 압축이 느림

- **증상**: 대화형으로 파일 하나 읽고 고치는 작업(Read+Edit)이 217초. 그중 자동 압축이 **125초**.
- **원인**: 기본 입력 약 11.3k + 압축 기준(창의 약 70%, 32k 창에서 약 22.6k 토큰)이라 실제 대화에 쓸 수 있는
  양이 약 10k 토큰입니다. 압축 자체도 같은 4B 모델이 요약하므로 오래 걸립니다.
- **해결**: 기본값을 **65536**으로 올렸습니다(`CLAUDE_LMS_CONTEXT`, gemma-4-e4b 최대 131072). 근거는 아래 측정.

**측정 (2026-11-02, test-mac M1 16GB, gemma-4-e4b-it-mlx 4bit)** — 긴 프롬프트 한 번을 보내며 모델 워커
프로세스의 메모리(`top` MEM = `footprint`)를 2초마다 기록:

| 로드 context | 프롬프트 토큰 | 처리 시간 | 워커 최대 메모리 | 처리 후 메모리 |
|---|---|---|---|---|
| 32768 | 4,059 | 17초 | 9,012 MB | 7,867 MB |
| 32768 | 22,180 (압축 직전 크기) | 89초 | 9,957 MB | 8,564 MB |
| 32768 | 28,232 | 118초 | 9,965 MB | 8,150 MB |
| 65536 | 44,339 (압축 직전 크기) | 193초 | 9,927 MB | 8,875 MB |
| 65536 | 58,432 | 266초 | (샘플 실패) | 8,846 MB |

- 로드 직후 메모리는 32768이든 65536이든 **약 7,970 MB로 같습니다**. MLX는 context 길이만큼 KV 캐시를
  미리 잡지 않고, gemma-4는 KV 캐시가 작아 처리 후 증가분이 수백 MB(약 14KB/토큰)입니다.
- 최대 메모리는 프롬프트 길이와 거의 무관하게 **약 10 GB** — 프롬프트를 처리하는 동안의 임시 버퍼입니다.
  이때 시스템 여유 메모리(`memory_pressure`)가 6~8%까지 내려갔으므로 16GB Mac에서 더 큰 모델은 무리입니다.
- 비용은 **시간**입니다. 압축할 때는 지금까지의 대화 전체를 요약하므로 64k 창에서는 한 번에 3분가량
  걸릴 수 있습니다. 대신 압축 횟수가 줄고, 평소 턴은 LM Studio의 프롬프트 캐시 덕에 새로 붙은 부분만
  처리합니다(`-p` 결과에서 입력 10,156 토큰 중 9,984 토큰이 캐시 적중).
- 참고: `lms ps`의 SIZE(6.86 GB)는 모델 파일 크기이고, `ps`의 RSS(약 0.5 GB)에는 Metal(GPU) 메모리가 빠져
  있어 둘 다 실제 사용량이 아닙니다. `footprint -p <pid>`의 "IOAccelerator (graphics)" 항목이 대부분입니다.

다른 값으로 바꾸려면:

```bash
./install-claude-code.sh --context=32768
```

또는 `~/.config/claude-lms/env`의 `CLAUDE_LMS_CONTEXT`를 고친 뒤 모델을 다시 로드합니다. 이미 설정 파일이
있는 Mac에서 설치 스크립트를 다시 돌리면 **기존 값이 유지**됩니다(새 기본값이 덮어쓰지 않음).

### 1.6 첫 실행 화면: 폴더 신뢰 질문의 기본 선택이 "No, exit"

- **증상**: 처음 `claude-lms`를 실행하고 Enter만 누르면 바로 종료됨.
- **원인**: 새 HOME(`~/.claude.json` 없음)에서는 다음 순서로 화면이 나옵니다.
  1. 테마 선택
  2. Security notes — Enter
  3. 현재 폴더 신뢰 여부 — **기본 선택이 "No, exit"**
- **해결**: 3번에서 ↓ 로 "Yes"를 고른 뒤 Enter. 한 번 지나가면 `hasCompletedOnboarding`이 기록되어 다시
  묻지 않습니다. 인증 토큰을 환경변수로 넘기므로 **로그인 화면은 나오지 않습니다**.
- **확인**: 상단에 `gemma-4-e4b-it-mlx · API Usage Billing` 처럼 로컬 모델 이름이 표시됩니다
  ("API Usage Billing" 문구는 표시일 뿐, 요청은 LM Studio로만 갑니다).

### 1.7 기본 권한 모드가 auto mode

- **증상**: 첫 실행부터 권한 모드가 auto mode로 표시됨.
- **영향**: auto mode의 판정(classifier) 호출도 같은 로컬 모델로 갑니다. 4B 모델에서 판정 품질과 속도가
  어떤지는 **아직 평가하지 않았습니다**. 신중하게 쓰려면 실행 중 Shift+Tab으로 모드를 바꿀 수 있습니다.

### 1.8 gemma-4-e4b(4B)는 에이전트 작업에 약함

- **증상**: "이 파일 고쳐줘"처럼 모호하게 요청하면 Read 도구를 쓰지 않고 파일 내용을 붙여 달라고 함.
  결과 보고도 부정확한 경우가 있음(실제 출력 `4.0`을 `4`라고 보고).
- **해결/운영 지침**: 도구 사용을 명시하면 동작합니다 — 예: "Read 도구로 calc.py를 읽고, Edit로 고친 뒤
  Bash로 실행해 결과를 보여 줘". 측정값: `-p` 수정 작업 4턴 95초, 대화형 Read+Edit 217초(압축 포함).
- **참고**: 12B급 모델은 16GB Mac에서 Open WebUI·임베딩 모델과 함께 올릴 수 없습니다. 결과는 반드시
  사람이 확인하세요.

### 1.9 `claude -p`가 스크립트의 나머지 stdin을 먹어 버림

- **증상**: ssh나 heredoc으로 넘긴 테스트 스크립트에서 `claude -p` 다음 명령들이 실행되지 않음.
- **원인**: `claude -p`는 stdin이 열려 있으면 그것을 입력으로 읽습니다.
- **해결**: 스크립트 안에서는 `claude-lms -p "..." < /dev/null` 로 실행합니다.

### 1.10 모델 id가 Mac마다 다름

- **증상**: 한 Mac에서 쓰던 `google/gemma-4-e4b`를 다른 Mac에 넣으면 LM Studio가 모델을 찾지 못함.
- **원인**: LM Studio는 파일이 놓인 위치로 id를 붙입니다. 직접 받은 모델은 `google/gemma-4-e4b`, 번들이
  넣은(side-load) 모델은 `gemma-4-e4b-it-mlx`.
- **해결**: `install-claude-code.sh`가 다음 순서로 모델을 정하고, `/v1/models` 목록에 있는지 검사합니다.
  1. `--model=ID`
  2. 기존 `~/.config/claude-lms/env`
  3. wiki의 `WIKI_INGEST_MODEL` (`~/llm-wiki/.env`) — 같은 모델을 쓰면 메모리에 하나만 올라감
  4. LM Studio가 나열하는 첫 LLM (임베딩 모델 제외)

  그래서 `install-all.sh`는 wiki 단계 **다음에** Claude Code 단계를 실행합니다.

### 1.11 USB/네트워크로 복사한 바이너리의 quarantine

- **증상**: 복사해 온 `claude` 실행 시 Gatekeeper가 막을 수 있음.
- **원인**: 단일 Mach-O 파일에는 공증 티켓을 붙일(staple) 수 없어서, 오프라인에서는 Gatekeeper가 확인할
  방법이 없습니다.
- **해결**: 설치 스크립트가 먼저 서명을 직접 검증합니다 — `codesign --verify --strict`,
  `TeamIdentifier=Q6L2SF6YDW`(Anthropic), `Identifier=com.anthropic.claude-code`. 통과한 **그 파일 하나만**
  `xattr -d com.apple.quarantine`. (`xattr -cr`이나 Gatekeeper 끄기는 쓰지 않습니다.) 복사 후 한 번 더
  검증하고, `.partial` 이름으로 복사한 뒤 옮기므로 중간에 끊겨도 반쯤 복사된 파일이 쓰이지 않습니다.
- **확인**: `codesign -dv ~/.local/bin/claude 2>&1 | grep TeamIdentifier`, `xattr ~/.local/share/claude/versions/*`.

### 1.12 `~/.local/bin`이 PATH에 없음

- **증상**: 설치 후 `claude-lms: command not found`.
- **원인**: macOS 기본 zsh에는 `~/.local/bin`이 PATH에 없습니다.
- **해결**: `~/.zshrc`에 표시 블록(`# >>> claude-code (llm-wiki bundle) >>>`)을 한 번만 추가합니다. 새 터미널부터
  적용됩니다. 원치 않으면 `--no-path`.
- **함께 고친 문제**: "이미 PATH에 있는지" 검사가 주석 줄(`# export PATH=...local/bin`)에도 걸려 PATH를
  추가하지 않았습니다. 주석이 아닌 줄만 보도록 `^[^#]*\.local/bin`으로 수정.

### 1.13 이미 설치된 claude와의 충돌

- **동작**: `~/.local/bin/claude`가 공식 설치(심볼릭 링크)이고 같거나 새 버전이면 **그대로 둡니다**.
  오래된 버전이면 새 버전 링크로 바꾸되 옛 버전 파일은 `versions/`에 남깁니다. 링크가 아닌 일반 파일이
  있으면 덮어쓰지 않고 중단합니다(직접 옮긴 뒤 다시 실행).

### 1.14 외부 통신 차단

- Claude Code는 기본적으로 업데이트 확인, 텔레메트리, 오류 보고를 Anthropic으로 보냅니다. `claude-lms`는
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_AUTOUPDATER=1`을 설정합니다.
- 요청마다 바뀌는 attribution 헤더는 LM Studio의 프롬프트 캐시를 무효로 만들기 때문에
  `CLAUDE_CODE_ATTRIBUTION_HEADER=0`으로 끕니다.
- 번들에는 Anthropic API 키가 들어가지 않습니다. 인증 토큰은 더미 값(`lmstudio`)입니다.
- **오프라인(인터넷 차단) 상태에서 외부 접속 0건인지는 아직 확인하지 않았습니다** (3부).

### 1.15 테스트할 때 쓴 방법

- 대화형 화면은 `/usr/bin/expect`로 키 입력(↓ = `\033[B`)을 보내고 `log_file`로 기록, ANSI 코드를 제거해 확인:

  ```bash
  perl -pe 's/\e\[[0-9;?<>]*[ -\/]*[@-~]//g; s/\e\][^\a]*\a//g; s/\r/\n/g' tty.log
  ```

- expect에서 응답 문자열을 기다리면 **직접 입력한 프롬프트에 먼저 매칭**됩니다. 파일 내용 변화로 확인하세요.
- 세션 기록은 `~/.claude/projects/<폴더>/*.jsonl` (`usage`, `compactMetadata`로 토큰·압축 확인).
- 실제 HOME을 건드리지 않도록 임시 `HOME`과 깨끗한 PATH(`/usr/bin:/bin:/usr/sbin:/sbin`, bash 3.2)로 실행.

---

## 2부. 이전 번들 설치에서 생긴 문제

| # | 증상 | 원인 | 해결 |
|---|------|------|------|
| 2.1 | 번들의 LM Studio.app이 "손상됨"으로 표시 | 한 번 실행한 앱은 첫 실행 때 파일을 `~/.lmstudio`로 옮겨 코드 서명 봉인이 깨짐 | 공식 dmg를 그대로 번들에 넣고 설치 시 마운트해 복사(옵션 B). `codesign --verify --deep --strict`로 확인 |
| 2.2 | 첫 실행에서 앱이 뜨지 않고 멈춤(`_dyld_start`) | Gatekeeper 대화상자가 콘솔 화면에 떠서 누군가 답할 때까지 대기. 같은 경로의 옛 "손상됨" 대화상자도 새 실행을 잡음 | 공증 티켓이 붙은 dmg 앱 사용(대화상자 없음 확인). 화면에서 대화상자 확인 |
| 2.3 | `open -a "LM Studio"`가 엉뚱한 앱 실행 | 백업 폴더 안의 복사본이 먼저 선택됨 | 항상 `open "/Applications/LM Studio.app"` |
| 2.4 | 새 설치에서 :1234 서버가 안 뜸 | 새 LM Studio는 `~/.lmstudio/.internal/http-server-config.json`을 만들지 않음 | `install-wiki.sh`가 `{"port":1234,"autoStartOnLaunch":true}`로 생성 |
| 2.5 | 설정 후에도 :1234가 꺼져 있음 | `autoStartOnLaunch`는 **다음 실행부터** 적용 | 앱이 실행 중이고 :1234가 꺼져 있으면 `lms server start --port 1234` |
| 2.6 | 앱이 종료되지 않음 | `enableLocalService`가 켜지면 종료·SIGTERM을 무시하고 백그라운드 서비스로 남음 | 콜드 스타트 테스트는 앱과 `~/.lmstudio/.internal/utils/node` 프로세스를 SIGKILL |
| 2.7 | wiki ingest 중 gemma 로드가 취소됨 | `unloadPreviousJITModelOnLoad`(기본 true): 임베딩 요청이 이전 JIT 모델을 내림 | `install-wiki.sh`가 false로 설정(앱 실행 중 변경해야 적용) |
| 2.8 | 첫 색인 후 Chroma 0행, 영구히 | wiki-mcp 0.2.0이 임베딩 실패한 노트도 캐시 | 0.2.1: 저장소에 없는 id 재임베딩. 확인은 `chroma.sqlite3`의 `select count(*) from embeddings` |
| 2.9 | watch가 쓴 노트가 검색에 안 보임 | 0.2.2까지 mcpo와 watch가 같은 Chroma에 씀(mcpo의 메모리 HNSW는 갱신 안 됨) | 0.2.3: mcpo의 wiki-mcp만 저장소에 쓰고 watch는 BM25만 |
| 2.10 | 한국어 검색에서 `index` 노트가 1위 | Hybrid RRF가 질의 토큰이 하나도 없는 BM25 결과에도 순위 표를 줌 | 0.2.4: 질의 토큰을 포함한 노트만 투표 |
| 2.11 | raw ingest "No models loaded" | `WIKI_INGEST_MODEL=google/gemma-4-e4b`인데 번들 모델 id는 `gemma-4-e4b-it-mlx` (1.10과 같은 원인) | 번들 모델 id로 수정 |
| 2.12 | 깨끗한 Mac에서 스크립트 오류 | 테스트 Mac은 Homebrew bash 5가 먼저, 실제 새 Mac은 `/bin/bash` 3.2뿐. python3도 없음 | 깨끗한 PATH로 테스트, JSON은 `plutil`로 읽기 |
| 2.13 | `log show`가 이상하게 동작 | zsh에 `log` 내장 명령이 있음 | `/usr/bin/log` 전체 경로 사용 |
| 2.14 | prod-mac 재부팅 후 서비스가 안 뜸 | FileVault 잠금 해제와 사용자 로그인 전에는 LaunchAgent가 시작되지 않음 | 화면에서 잠금 해제·로그인 후 확인 |
| 2.15 | 한국어 RAG 검색 품질 낮음 | nomic 임베딩은 한국어 top-1 3/14 | bge-m3(14/14)로 교체, 재색인 |

---

## 3부. 남은 과제

- [x] **기본 context 결정**: 32768 → 65536 (1.5의 측정). 새 기본값으로 설치 → 32768 로드 상태에서 비대화형
      실행은 reload 명령을 보여 주고 종료, 미로드 상태에서는 65536으로 자동 로드 후 `-p` 응답 확인(test-mac).
- [ ] **64k 창에서 대화형 압축 시간**: 실제 Claude Code 세션에서 압축이 몇 초 걸리는지 측정.
- [ ] **오프라인 검증**: 인터넷을 끊은 test-mac에서 `claude-lms` 실행 → 외부 접속 0건 확인.
- [ ] **auto mode 평가**: 4B 모델로 권한 판정이 쓸 만한지, 기본 모드를 바꿀지.
- [x] **prod-mac 설치** (2026-11-02): 키트 `~/Desktop/project/claude-code-2.1.316`(sha256 확인)에서
      `install-claude-code.sh` 실행 → Claude Code 2.1.316, 모델 `google/gemma-4-e4b`(WIKI_INGEST_MODEL), context
      65536, `~/.zshrc` PATH 블록(원본은 키트 폴더의 `zshrc.before-*`). 미로드 상태에서 `claude-lms -p`가 65536으로
      로드(8초) 후 `pong`, 전체 26초. 이후 여유 메모리 34%. 이 Mac의 JIT 기본 context는 4096이므로 Open WebUI가
      나중에 모델을 내리고 다시 JIT 로드하면 `claude-lms`가 다시 로드를 묻습니다(1.2).
- [ ] **prod-mac 대화형 첫 실행**: 테마·신뢰 화면(1.6)을 사용자가 직접 통과.
