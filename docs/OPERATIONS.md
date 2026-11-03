# 상시 운영 — 서비스 기동·자동 시작·점검

번들은 최대 **3개 프로세스**로 구성됩니다. 이 문서는 이들을 **안정적으로 상시 운영**하는 방법을 다룹니다.

> 최초 연결·검증은 [`USAGE.md`](USAGE.md), 설치는 [`../INSTALL.md`](../INSTALL.md)를 참조하세요.

---

## 1. 구성 요소

| 프로세스 | 포트 | 역할 | 필수 |
| --- | --- | --- | --- |
| `open-webui serve` | 8080 | 채팅 UI | ✅ |
| `run-wiki-mcp.sh mcpo` | 8766 | Open WebUI ↔ wiki-mcp REST 브리지 | ✅ (방식 A) |
| `run-wiki-mcp.sh watch` | — | `raw/` 감시 → 자동 위키화 + 재인덱싱 | 선택 |

`watch`는 `raw/`에 원문을 넣는 워크플로를 쓸 때만 필요합니다.
쓰지 않더라도 노트를 직접 편집했다면 `reindex` 도구로 갱신할 수 있습니다.

---

## 2. 수동 기동 (개발·단발성)

터미널 3개, 또는 백그라운드:

```bash
cd <번들 경로>
source .venv/bin/activate
export HF_HUB_OFFLINE=1 OFFLINE_MODE=1

open-webui serve            > logs/openwebui.log 2>&1 &
./run-wiki-mcp.sh mcpo      > logs/mcpo.log      2>&1 &
./run-wiki-mcp.sh watch     > logs/watch.log     2>&1 &
```

종료:

```bash
pkill -f "open-webui serve"
pkill -f "mcpo --port"
pkill -f "wiki-mcp-watch"
```

> **주의**: `watch`는 raw 변환 중 감시 스레드를 블록합니다(모델 추론 시간만큼).
> 대량 문서를 넣을 때는 변환이 끝날 때까지 다른 파일 이벤트가 대기합니다.

---

## 3. 자동 시작 (macOS launchd) — 권장

로그인 시 자동 기동하고, 죽으면 자동 재시작합니다.
`~/Library/LaunchAgents/` 에 아래 plist를 만듭니다. **`<번들 경로>`를 실제 경로로 바꾸세요.**

### 3-1. Open WebUI — `dev.example.openwebui.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>dev.example.openwebui</string>
  <key>ProgramArguments</key>
  <array>
    <string><번들 경로>/.venv/bin/open-webui</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key><string><번들 경로></string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HF_HUB_OFFLINE</key><string>1</string>
    <key>OFFLINE_MODE</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string><번들 경로>/logs/openwebui.log</string>
  <key>StandardErrorPath</key><string><번들 경로>/logs/openwebui.log</string>
</dict></plist>
```

### 3-2. mcpo 브리지 — `dev.example.wiki-mcpo.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>dev.example.wiki-mcpo</string>
  <key>ProgramArguments</key>
  <array>
    <string><번들 경로>/run-wiki-mcp.sh</string>
    <string>mcpo</string>
  </array>
  <key>WorkingDirectory</key><string><번들 경로></string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string><번들 경로>/logs/mcpo.log</string>
  <key>StandardErrorPath</key><string><번들 경로>/logs/mcpo.log</string>
</dict></plist>
```

### 3-3. watch 데몬 — `dev.example.wiki-watch.plist`

`raw/` 자동 변환을 쓸 때만. LLM 설정이 필요합니다.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>dev.example.wiki-watch</string>
  <key>ProgramArguments</key>
  <array>
    <string><번들 경로>/run-wiki-mcp.sh</string>
    <string>watch</string>
  </array>
  <key>WorkingDirectory</key><string><번들 경로></string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>WIKI_INGEST_ENABLED</key><string>1</string>
    <key>WIKI_INGEST_URL</key><string>http://localhost:1234/v1/chat/completions</string>
    <key>WIKI_INGEST_MODEL</key><string>google/gemma-4-e4b</string>
    <key>WIKI_INGEST_TEMPLATE</key><string>concept</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string><번들 경로>/logs/watch.log</string>
  <key>StandardErrorPath</key><string><번들 경로>/logs/watch.log</string>
</dict></plist>
```

### 등록 / 해제

```bash
mkdir -p <번들 경로>/logs
launchctl load  ~/Library/LaunchAgents/dev.example.openwebui.plist
launchctl load  ~/Library/LaunchAgents/dev.example.wiki-mcpo.plist
launchctl load  ~/Library/LaunchAgents/dev.example.wiki-watch.plist   # 선택

launchctl list | grep example          # 상태 확인
launchctl unload ~/Library/LaunchAgents/dev.example.wiki-mcpo.plist   # 해제
```

---

## 4. 헬스 체크

```bash
# 포트
lsof -nP -iTCP:8080 -sTCP:LISTEN   # Open WebUI
lsof -nP -iTCP:8766 -sTCP:LISTEN   # mcpo

# 응답
curl -s -o /dev/null -w "openwebui %{http_code}\n" http://localhost:8080/
curl -s -H "Authorization: Bearer $WIKI_MCPO_KEY" \
  -X POST http://localhost:8766/get_wiki_stats -H "Content-Type: application/json" -d '{}'

# watch 데몬
pgrep -fl wiki-mcp-watch
```

정상이면 `get_wiki_stats`가 노트 수·링크 수를 반환합니다.

---

## 5. 로그

| 대상 | 위치 | 무엇을 보는가 |
| --- | --- | --- |
| Open WebUI | `logs/openwebui.log` | 기동 실패, 모델 연결 오류 |
| mcpo | `logs/mcpo.log` | 브리지 기동, 도구 등록 |
| watch | `logs/watch.log` | **raw 변환 진행/실패** (`📥 raw 변환 시작` → `✅ 노트 생성`) |

raw 변환이 실패하면 원문이 `raw/.failed/`로 이동하고 사유가 `watch.log`에 남습니다.

---

## 6. 데이터·백업

| 대상 | 경로 | 백업 필요 |
| --- | --- | --- |
| **위키 노트** | `wiki/` | **필수** — 유일한 원본 데이터 |
| 원문 아카이브 | `raw/.processed/` | 권장 |
| Open WebUI DB | `open_webui` 패키지 내부 `data/` 또는 `DATA_DIR` | 권장 (대화·계정) |
| 검색 인덱스 | `wiki-data/` | 불필요 — 재인덱싱으로 복구 |
| 가상환경 | `.venv/` | 불필요 — `install.sh`로 재생성 |

```bash
# 최소 백업 (노트 + 원문)
tar -czf wiki-backup-$(date +%Y%m%d).tar.gz wiki/ raw/.processed/
```

`wiki/`만 있으면 인덱스·환경은 모두 복구됩니다. 노트가 곧 데이터입니다.

---

## 7. 운영상 알려진 제약

| 제약 | 내용 | 완화 |
| --- | --- | --- |
| watch 단일 스레드 | raw 변환 중 다른 파일 이벤트가 대기 | 대량 투입 시 작은 모델 사용, 또는 나눠서 투입 |
| 변환 지연 | 노트 1개당 LLM 1회 (로컬 12B ≈ 77초) | 작은 모델(`gemma-4-e4b` ≈ 46초) 권장 |
| ID 충돌 | 같은 id의 노트가 있으면 변환 실패 | 원문이 `raw/.failed/`로 이동 — 로그 확인 후 수동 처리 |
| OCR 미지원 환경 | `ocr/vision-ocr` 없으면 스캔 PDF 실패 | `package.sh`가 빌드하여 번들에 포함 (macOS 전용) |

---

## 8. 향후 개선 후보

- **변환 비동기화** — watch의 감시 스레드와 변환 워커 분리 (대량 투입 시 블로킹 해소)
- **재시도 정책** — `raw/.failed/` 자동 재시도 (모델 일시 오류 대응)
- **헬스 체크 스크립트** — 위 4장을 `health.sh`로 묶어 launchd 주기 실행
