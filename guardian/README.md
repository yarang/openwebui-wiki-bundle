# LLM + Wiki 통합 번들 (guardian 기반)

인터넷 없이 Mac 한 대에 **LM Studio + Open WebUI + 사내 위키(wiki-mcp) + Claude Code** 를 설치하는 번들이다.

| 구성 | 내용 |
|---|---|
| LM Studio | 앱 · llama.cpp/MLX 런타임 · `gemma-4-e4b-it-mlx` (gemma-4-E4B MLX 4bit, 위키 raw 변환·채팅) |
| 임베딩 | `text-embedding-bge-m3` (bge-m3 GGUF Q8, 1024차원, `lmstudio-home/models/gpustack/bge-m3-GGUF` 에 동봉) — 위키 검색과 Open WebUI RAG 가 함께 쓴다 |
| Open WebUI | Python 3.12 venv `~/.guardian-llm`, LaunchAgent `dev.guardian.openwebui` (:8080) |
| 위키 | wiki-mcp · mcpo(127.0.0.1:8766) · raw 자동변환 watch, 홈 `~/llm-wiki` |
| Claude Code | Anthropic 서명 네이티브 바이너리(빌드 Mac 의 것을 서명 확인 후 복사) + `claude-lms`(LM Studio 로 연결, Anthropic 계정 불필요). `install-all.sh` 마지막 단계가 `~/.local/bin` 에 설치. 빌드 때 `--no-claude-code` 면 뺀다 |

## 설치

빌드 Mac 이 만든 파일 세 개를 대상 Mac 의 한 폴더(예: `~/bundles`)에 복사하고 설치 스크립트를 돌린다.

```bash
# llm-wiki-bundle-<시각>-macos-arm64.tar.xz, 같은 이름.tar.xz.sha256, install-llm-wiki.sh
bash install-llm-wiki.sh --dry-run     # 체크섬·여유 공간 확인, 압축 풀기, 무엇을 할지 보기
bash install-llm-wiki.sh               # 설치 + 기동 + LM Studio 첫 실행 + 위키 단계 재실행
```

- 스크립트 순서: 압축 파일 sha256 → 여유 공간(압축 파일의 2.5배 + 2GB) → 같은 폴더에 풀기(`/usr/bin/tar -xJf`, 클린 Mac 에 기본으로 있다) → 번들의 `install-all.sh`(번들의 공식 dmg 에서 LM Studio 설치 포함) → LM Studio 첫 실행 → `wiki-layer/install-wiki.sh` 재실행.
- 이미 풀린 번들 폴더가 있으면 다시 풀지 않고 쓴다. 풀다 멈춘 `.<이름>.extracting` 폴더가 남아 있으면 지우지 않고 멈춘다.
- `install-all.sh` 옵션(`--webui-host=0.0.0.0`, `--migrate-from=…` 등)은 그대로 넘긴다. `--skip-verify` 는 압축 파일 sha256 도 건너뛴다. `--no-start` 면 LM Studio 를 열지 않는다.
- LM Studio 가 180초(`--launch-timeout=S`) 안에 뜨지 않으면 종료 코드 3 으로 멈춘다. 대상 Mac 화면에 Gatekeeper 창이 떠 있을 수 있으니 답한 뒤 `cd <번들>/wiki-layer && ./install-wiki.sh` 를 돌린다.
- 이미 LM Studio 를 쓰던 Mac 이고 `:1234` 가 응답하면 첫 실행 단계는 건너뛴다. 설치된 앱이 번들과 같거나 새 버전이면 dmg 도 열지 않는다.

풀린 폴더에서 직접 설치할 수도 있다(위 스크립트가 하는 일과 같다).

```bash
cd llm-wiki-bundle-*
./install-all.sh --dry-run     # 무엇을 할지 확인
./install-all.sh               # 설치 + 기동
```

- `install.sh` (guardian, `--no-app`) → LM Studio 앱 → `wiki-layer/install-wiki.sh` 순서로 실행된다. guardian 설치기는 Open WebUI LaunchAgent 를 매번 새로 쓰므로 위키 단계가 반드시 뒤에 온다.
- 번들의 `app/` 에는 앱 대신 공식 LM Studio dmg 가 들어 있다. `install-all.sh` 가 dmg 를 마운트해(Finder 에 나타나지 않음) 앱을 `/Applications`(쓸 수 없으면 `~/Applications`)로 복사한다. dmg 를 열어 끌어다 놓는 것과 같다. 규칙은 guardian 설치기와 같다: 같거나 새 버전이 이미 있으면 그대로 두고, 옛 버전은 `--upgrade-app` 일 때만(LM Studio 를 끈 상태에서) `LM Studio.app.old-<버전>` 으로 옮긴 뒤 바꾼다. 복사본은 quarantine 표시를 지우고 `codesign --verify --deep --strict` 를 통과해야 제자리로 옮겨진다.
- 직접 설치하고 싶으면 `--no-app` 을 주고 `app/LM-Studio-*.dmg` 를 열어 앱을 Applications 로 끌어다 놓는다.
- sudo 와 다운로드가 필요 없다. 체크섬 검증(`MANIFEST.sha256`)은 번들 전체를 한 번 읽는다.
- 같은 LAN 에서 접속하게 하려면 `--webui-host=0.0.0.0`. **관리자 계정을 먼저 만든 뒤에** 연다.

이 경우 설치가 끝나면 LM Studio 를 콘솔에서 한 번 열고(`open "/Applications/LM Studio.app"` — `open -a "LM Studio"` 는 백업 폴더 등 다른 사본을 열 수 있다), 위키 단계를 한 번 더 돌린다.

```bash
cd wiki-layer && ./install-wiki.sh   # LM Studio 서버 자동 시작을 켜고, 서버를 띄우고, 위키 서비스를 재기동
```

- LM Studio 는 켜 둔 채로 돌린다. 앱이 꺼진 동안 쓴 `enableLocalService` 는 다음 실행 때 앱이 되돌린다.
- 같은 단계에서 `developer.unloadPreviousJITModelOnLoad` 를 끈다. 켜져 있으면(기본값) 모델 하나를 로드할 때 앞서 로드한 모델을 내리므로, raw 변환 중인 gemma 를 bge-m3 임베딩 요청이 취소시킨다(`Failed to load model … Operation canceled` → 변환 400). 끈 뒤에는 두 모델이 함께 올라간다(약 7.5GB).
- 자동 시작(`autoStartOnLaunch`)은 다음 실행부터 적용되고, 켜진 뒤에는 앱이 종료 요청·SIGTERM 을 무시하고 백그라운드 서비스로 남는다. 그래서 이 회차에는 스크립트가 `~/.lmstudio/bin/lms server start --port 1234` 로 서버를 바로 띄운다(오프라인에서도 동작).
- 첫 설치 때는 LM Studio 서버가 아직 없어 임베딩이 전부 실패하고(`mcpo.log` 의 `❌ … port=1234`), wiki-mcp 는 BM25 만으로 검색한다. 재기동 때 저장소에 임베딩이 없는 노트를 다시 임베딩한다(wiki-mcp 0.2.1 부터. 0.2.0 은 실패한 노트도 캐시에 적어 dense 인덱스가 계속 비어 있었다).
- LM Studio 의 모델 id 는 파일이 놓인 폴더에서 정해진다. 설치 마지막에 `.env` 의 `EMBEDDING_MODEL`·`WIKI_INGEST_MODEL` 이 `/v1/models` 에 있는지 확인해 알려 준다(목록에는 로드하지 않은 모델도 나온다).
- `검색 모드: Hybrid` 로그 줄은 설정만 보여 준다. 실제로 임베딩됐는지는 `mcpo.log` 의 `임베딩 갱신: N개` 와, 그 뒤에 `❌` 가 없는지로 본다.

## 번들 만들기 (빌드 Mac)

```bash
guardian/build-merged-bundle.sh dist/build/<guardian 번들> \
    --lmstudio-dmg=LM-Studio-<버전>-arm64.dmg --name=llm-wiki-bundle-<UTC시각>-macos-arm64
```

- `--lmstudio-dmg` 는 꼭 줘야 한다(이 스크립트로 만든 번들을 다시 돌릴 때는 `MANIFEST.env` 의 `app_dmg` 로 `app/` 안의 dmg 를 다시 쓴다). 빌드는 dmg 를 마운트해 앱의 서명(`codesign --verify --deep --strict`)과 공증 티켓(`stapler validate`)을 확인하고, 버전·최소 macOS·nomic 모델을 그 앱에서 읽는다. 그런 다음 `app/` 에 dmg 하나만 남기고 원본 번들의 `app/LM Studio.app` 은 지운다.
- 앱 대신 dmg 를 싣는 까닭: LM Studio 는 처음 실행될 때 앱 안의 `bundled-models`(nomic)·extensions 를 `~/.lmstudio` 로 옮긴다. 한 번이라도 실행된 앱을 복사하면 서명이 깨져 대상 Mac 에서 "손상됨"으로 휴지통에 들어가고 nomic 도 빠진다. dmg 는 읽기 전용이라 그 안의 앱은 서명된 그대로이고, 대상 Mac 은 늘 공증된 원본을 받는다.
- bge-m3 는 빌드 Mac 의 `~/.lmstudio/models/gpustack/bge-m3-GGUF/bge-m3-Q8_0.gguf` 를 넣는다(다른 곳이면 `--embedding-gguf=PATH`). sha256 이 고정값과 다르면 빌드가 멈춘다. MLX 변환본은 LM Studio 가 LLM 으로 분류하므로 GGUF 만 쓴다.
- 한국어 검색 비교(test-mac, 질의 14개 top-1): bge-m3 14/14, nomic 3/14. nomic 은 앱에 딸려 오므로 그대로 두지만 쓰지 않는다.
- `--name` 을 주지 않으면 원본 번들의 생성 시각으로 이름을 지어, 같은 번들로 다시 돌릴 때 "already exists" 로 멈춘다.
- 마지막 단계는 `guardian/pack-bundle.sh <번들 폴더>` 로, 번들 옆에 대상 Mac 에 복사할 세 파일(`.tar.xz`, `.tar.xz.sha256`, `install-llm-wiki.sh`)을 쓴다. `--no-tar` 로 빌드했으면 나중에 직접 돌린다. Homebrew `xz` 가 있으면 코어를 모두 써서 압축하고, 없으면 `/usr/bin/tar` 내장 xz(코어 1개)를 쓴다. 다 쓴 뒤 `/usr/bin/tar` 로 목록을 다시 읽어 항목 수가 폴더와 같을 때만 `.sha256` 을 쓴다. 같은 이름의 결과물이 있으면 덮어쓰지 않고 멈춘다.
- xz 를 고른 까닭: 클린 Mac 의 `/usr/bin/tar`(bsdtar)가 xz·gzip·bzip2 는 읽지만 zstd 는 못 읽는다. 앱·런타임·wheel 은 크게 줄고, 양자화된 모델 가중치는 조금만 준다.

## 기존 openwebui-wiki 번들(0.10.x)에서 옮기기

```bash
# 1) 옛 번들의 Open WebUI · wiki-mcp watch 를 모두 종료한다
# 2) 데이터를 복사(이동 아님)해 온다
./install-all.sh --migrate-from="$HOME"/Desktop/project/openwebui-wiki-bundle-0.10.2-macos-arm64
```

- 복사 대상: `webui.db`(+`-wal`/`-shm`), 업로드, 벡터DB, `.webui_secret_key`, `wiki/`, `raw/`.
- `wiki-data/`(위키 검색 인덱스)는 옛 `.env` 가 `EMBEDDING_DISABLED=0` 이고 같은 임베딩 모델일 때만 복사한다. 아니면 두고 오며, 첫 기동 때 `wiki/` 에서 다시 만든다.
- 위키 설정은 튜닝 값(`WIKI_INGEST_MAX_*`·`TIMEOUT`·`TEMPLATE`·`EXT`·`XLSX_MAX_ROWS`·`OCR`, `WIKI_DEFAULT_TEMPLATE`)만 가져온다. 경로·mcpo 주소/키·모델 선택은 이 번들 값이다.
- DB 안의 위키 도구 서버 주소·키와 RAG 임베딩(→ LM Studio bge-m3)을 새 설치에 맞게 고친다. Open WebUI 는 한 번 저장된 설정을 DB 에서 읽기 때문에 환경변수로는 바뀌지 않는다.
- guardian 쪽에 이미 계정이 있으면 덮어쓰지 않고 멈춘다. 비어 있던 데이터는 `openwebui-data.pre-migrate-<시각>` 으로 남는다.
- 옛 번들 폴더는 그대로 두므로 되돌리기가 가능하다.

## 운영

```bash
launchctl kickstart -k gui/$(id -u)/dev.guardian.openwebui
launchctl kickstart -k gui/$(id -u)/dev.guardian.wiki-mcpo
launchctl kickstart -k gui/$(id -u)/dev.guardian.wiki-watch
tail -f ~/llm-wiki/logs/mcpo.log ~/llm-wiki/logs/watch.log
```

- 위키 설정: `~/llm-wiki/.env` (권한 600, mcpo 키 포함). 바꾼 뒤 위 두 위키 서비스를 재기동한다.
- 노트는 `~/llm-wiki/wiki/`, 검색 인덱스는 `~/llm-wiki/wiki-data/` (지워도 재인덱싱으로 복구).

## 알려진 제약

- 검증: prod-mac(기존 LM Studio 있음), 그리고 test-mac(LM Studio·`~/.lmstudio` 없는 클린 상태, 인터넷 차단)에서 확인했다. 번들 `20261026T070031Z`(LM Studio 0.4.26+4, wiki-mcp 0.2.4)로 설치 → LM Studio 첫 실행 → `install-wiki.sh` 재실행에서 서버 자동 시작·`check_models`(bge-m3, gemma 둘 다 있음)를 통과했고, 위키 저장소는 bge-m3 1024차원(컬렉션 metadata `embedding_model=text-embedding-bge-m3`), Open WebUI RAG 임베딩도 bge-m3 였다. raw 파일 하나가 gemma 를 거쳐 노트 2개가 되고 mcpo 재기동 없이 Chroma 행이 22 → 24 로 늘었으며, 질의 "호텔비 한도 넘으면 누가 승인해?" 에 새 노트가 hybrid 1위였다. 로그에 외부 접속 시도는 없었다. 강제 종료(SIGKILL) → 재실행 3초 만에 `:1234` 가 스스로 뜬다. 같은 번들을 `pack-bundle.sh` 로 압축한 7.0GB `.tar.xz` 를 복사해 `install-llm-wiki.sh` 하나로 설치했을 때도 같은 확인을 모두 통과했다(test-mac M1: 체크섬 + 풀기 5분 21초, 전체 7분 50초, 종료 코드 0). LM Studio 첫 실행과 위키 단계 재실행이 사람 손 없이 이어졌고, 앱이 다시 저장한 뒤에도 설정이 남았으며, 풀린 앱의 서명도 유효했다. 앱 대신 공식 dmg 를 넣은 번들 `20261027T130325Z`(7.2GB, dmg 가 이미 압축돼 있어 0.2GB 커짐)도 같은 클린 test-mac 에서 인터넷을 끊고 통과했다(전체 8분, 종료 코드 0): dmg 에서 `/Applications` 로 설치된 앱의 서명이 유효하고 quarantine 표시·임시 폴더·붙은 이미지가 남지 않았으며, Gatekeeper 대화상자 없이 첫 실행이 이어졌다. 앱이 켜진 채 다시 실행하면 dmg 를 열지 않고 "same or newer: kept" 로 넘어가 47초 만에 끝났다. 로그인(재부팅) 직후 LM Studio 가 스스로 뜨는지는 확인하지 않았다.
- 위키 검색 저장소(ChromaDB, `index_cache.json`)에는 mcpo 가 띄운 wiki-mcp 만 쓴다(wiki-mcp 0.2.3 부터). Chroma 는 프로세스마다 검색 인덱스를 메모리에 두어서, 0.2.2 까지는 watch 가 임베딩한 노트가 mcpo 를 재기동할 때까지 dense 검색에 잡히지 않았다. 이제 watch 는 Markdown 만 쓰고, mcpo 쪽 wiki-mcp 가 위키 폴더 변경을 보고(2초 디바운스) 스스로 임베딩한다. 편집기로 고친 노트도 같다. watch 가 raw 변환 때 고르는 링크 후보는 BM25 로만 찾는다. test-mac 에서 재기동 없이 새 노트가 들어오고(Chroma 25 → 27) dense 순위 1위였으며, 저장소 파일을 연 프로세스는 mcpo 쪽 wiki-mcp 하나였다.
- 한국어 질의는 조사 때문에 노트와 한 토큰도 겹치지 않기 쉽다. 이전에는 그때도 모든 노트가 BM25 순서대로 RRF 표를 받아 엉뚱한 노트(예: `index`)가 dense 1위를 앞섰다(위 확인에서 새 노트는 hybrid 2위). wiki-mcp 0.2.4 부터는 질의 토큰이 있는 노트만 BM25 표를 받는다.
- 옛 번들에서 옮긴 첨부파일 벡터는 MiniLM(384차원)이다. 해당 지식베이스는 Open WebUI 에서 재인덱싱해야 bge-m3 로 검색된다. 이미 쓰던 Open WebUI DB 는 RAG 임베딩 설정을 DB 에서 읽으므로, 옮기기(`--migrate-from`)가 아니면 관리자 설정에서 직접 바꾼다.
- 위키 임베딩 모델을 바꾸면(`.env` 의 `EMBEDDING_MODEL`) wiki-mcp 0.2.2 부터 다음 기동 때 저장소를 새로 만들고 전부 다시 임베딩한다(모델 이름을 Chroma 컬렉션 metadata 에 적어 비교). 0.2.1 이하는 옛 벡터가 남아 dense 검색이 조용히 실패했다.
- 기존 설치의 `.env` 는 지키되, 값이 옛 기본값(`google/gemma-4-e4b`, nomic)일 때만 새 기본값으로 바꾼다.
