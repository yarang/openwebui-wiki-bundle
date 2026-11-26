# llm-router

LM Studio(이 Mac의 로컬 소형 모델)와 DGX Spark의 vLLM(LAN)을 **하나의 Anthropic 호환 base URL**로
묶는 얇은 로컬 프록시. Claude Code는 `http://127.0.0.1:1240` 하나만 바라보고, 라우터가 백엔드를
고른다. 둘 다 Anthropic `/v1/messages`를 이미 지원하므로 형식 변환은 없고, 라우터는 `model` 필드
재작성, 인증 헤더 설정, 응답 스트리밍, 장애 시 로컬 폴백만 담당한다.

## 별칭과 모델 id

| 요청 model | 동작 |
|---|---|
| `spark-large` | Spark로. `SPARK_PREFER` 중 Spark가 실제로 서빙 중인 첫 id, 없으면 목록 첫 모델 |
| `local-fast` | 로컬로, `LOCAL_MODEL` 사용 |
| 로컬 카탈로그의 id (또는 `LOCAL_MODEL`) | 로컬로 그대로 |
| Spark 카탈로그의 id | Spark로 그대로 |
| 그 외 | 400 (spark-switch 프로필이면 로드 안내, 로드 중이면 503 — 아래 "Spark 모델 교체") |

응답은 항상 `X-Route` 헤더로 실제 간 경로를 알려준다: `spark`, `local`, `local (spark-down)`
(Spark가 꺼져 있어 처음부터 로컬로 보낸 경우), `local (retry)` (Spark에 연결 실패, 응답 헤더 전
끊김(`ReadError`·`RemoteProtocolError`·`WriteError`), 502/503 후 로컬로 재시도한 경우). 그 외
상태(2xx, 4xx, 500, 504)는 그대로 전달된다 — 504(gateway timeout)와 헤더 전 `ReadTimeout`은
재시도하지 않는다. 그 시점에 요청이 Spark에서 아직 실행 중일 수 있어, 로컬로 넘겨 재실행하면 같은
프롬프트가 두 번 실행되기 때문이다.

`/v1/messages` 스트림(압축 없는 200 SSE)이 `message_stop` 없이 끝나면(모델 교체로 슬롯이 내려간
경우 등) 받은 조각 뒤에 `event: error`(`api_error`) 하나를 붙여 잘린 답임을 알린다.

## Spark 모델 교체 자동 반영

Spark는 한 번에 모델 하나만 서빙하고 그 모델이 바뀐다(qwen3-coder, gpt-oss-120b, …). 라우터는
`HEALTH_INTERVAL`(기본 10초)마다 양쪽 `GET /v1/models`를 probe해 카탈로그를 **통째로 교체**하므로,
Spark에서 모델을 갈아끼워도 다음 probe 안에 `spark-large`가 새 모델을 가리킨다. 모델 id를 하드코딩
하지 않는다. 건강 상태는 `HEALTH_FAIL`회 연속 실패로 down, `HEALTH_OK`회 연속 성공으로 up(시작 직후
첫 probe는 즉시 확정).

## Spark 모델 교체 (spark-model)

교체는 **명시적으로만** 일어난다 — 모델 요청 하나가 절대 서빙 모델을 바꾸지 않는다. 실제 교체는 Spark
안의 spark-switch 컨트롤러(`SPARK_SWITCH_URL`, LAN 평문 HTTP + Bearer 토큰)가 수행하고, 라우터는 그
`/status`를 health 주기마다 캐시할 뿐이다(컨트롤러 실패는 캐시를 stale로 만들 뿐 백엔드 상태에 영향 없음).

- **`spark-model status` / `list`** — 현재 모델, 컨트롤러 상태(phase), idle 복귀 시각, 프로필 표.
  **`spark-model use <profile> [--wait]`** / **`spark-model default [--wait]`** — 교체 요청. `--wait`는
  10초 간격으로 phase 변화를 출력하며 ready를 기다린다(최대 40분). 409(이미 전환 중)/429(쿨다운)는
  이유와 `retry_after`를 출력하고 exit 1. CLI는 라우터(`http://127.0.0.1:1240`)만 호출하므로 토큰이
  필요 없고, `install-llm-router.sh`가 `~/.local/bin/spark-model`로 설치한다.
- 로드되지 않은 프로필로 요청하면 400 안내가 온다: `... is a Spark profile but is not loaded
  (current: ...). Load it with: spark-model use <name>`. 같은 이름이 **로드 중**이면 503
  `overloaded_error` + `Retry-After: 60`("Spark is loading ... (phase ...); retry in a few minutes")
  — 이 경로는 로컬 폴백 없이 잠시 뒤 재시도하는 것이 맞다.
- `GET /v1/models`는 로드되지 않은 프로필도 `route: "spark (not loaded)"`, `kind`와 함께 보여준다.
- 일정 시간 idle이면 **Spark 쪽에서** 기본 프로필로 자동 복귀한다(idle auto-return은 라우터가 아니라
  Spark가 담당). 엔드포인트: `GET /v1/spark/status`, `POST /v1/spark/switch {"profile": ...}`.

## 환경 변수

`~/.config/llm-router/env` (mode 600 필수, Spark 키가 들어있음). 프로세스 환경이 파일보다 우선.
템플릿은 [env.example](env.example).

`LLM_ROUTER_HOST`(루프백만 허용) `LLM_ROUTER_PORT` `LOCAL_URL` `LOCAL_MODEL` `LOCAL_TOKEN`
`SPARK_URL`(비우면 Spark 비활성, 예: `http://spark.local:8000` — mDNS 이름은 DHCP 주소 변경을
따라가고, 직접 IP도 가능) `SPARK_URLS`(쉼표 목록, 예:
`http://spark.local:8000,http://spark.local:8001` — 각 URL을 따로 probe하고 요청은 그
모델을 서빙하는 URL로 간다. 설정 시 `SPARK_URL`보다 우선) `SPARK_API_KEY` `SPARK_PREFER`
`SPARK_SWITCH_URL`(비우면 스위치
기능 비활성, 예: `http://spark.local:8010`) `SPARK_SWITCH_TOKEN` `HEALTH_INTERVAL` `HEALTH_FAIL`
`HEALTH_OK` `CONNECT_TIMEOUT` `HEALTH_TIMEOUT` `MAX_BODY_MB`
`UPSTREAM_IPV4_ONLY`(업스트림 연결을 IPv4로 강제, 기본 1 — IPv6 전용 업스트림 URL일 때만 0)
`ACCESS_LOG`(uvicorn의 요청별 access 로그, 기본 0 — 라우터가 프록시한 요청마다 이미 한 줄씩
기록하므로 중복이다. 1로 켜면 /health probe까지 매 요청 한 줄이 추가된다)

`GET /health`로 두 백엔드 상태를, `GET /v1/models`로 라우터가 서빙하는 전체 목록을 볼 수 있다.

## 설치 / 실행

```sh
guardian/llm-router/install-llm-router.sh            # 파일만 설치
guardian/llm-router/install-llm-router.sh --load     # 설치 + LaunchAgent 시작 + /health 확인
```

Claude Code kit(`claude-code-kit-*.tar.gz`)에도 `llm-router/` 폴더가 함께 들어 있다. 대상 Mac에서는

```sh
./install-claude-code.sh --with-router    # 라우터 설치 (시작은 안 함)
./install-claude-code.sh --router-load    # 설치 + LaunchAgent 시작
```

한 번으로 라우터와 `spark-model`, `~/.config/claude-lms/env`의 `CLAUDE_LMS_ROUTER`와
`CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct'`(없을 때만)까지 같이 설정된다. 통합 번들의 `install-all.sh`는
`--router-load`를 기본으로 넘긴다(`--no-router`로 끔).

처음 만드는 env에는 `SPARK_URLS=http://spark.local:8000,http://spark.local:8001`, `SPARK_URL=http://spark.local:8000`,
`SPARK_SWITCH_URL=http://spark.local:8010`이 들어간다. 다른 주소는 `--spark-url=URL`(쉼표 목록 가능, 첫 URL이
`SPARK_URL`, 스위치는 그 호스트의 8010)로 준다. 키는 kit에 넣지 않고
`--spark-env=FILE`로 준다. 파일에서 `SPARK_API_KEY`·`SPARK_SWITCH_TOKEN`(Spark 쪽 이름
`VLLM_API_KEY`·`SWITCH_TOKEN`도 받음)만 읽어 env에 옮기고, 값은 출력하지 않는다. 이미 있는 env는
이 두 옵션으로 준 키만 바뀐다. 옵션 없이 다시 설치하면 env는 그대로다.

```sh
./install-claude-code.sh --router-load --spark-env="$HOME/spark-keys.env"
``` kit의 `llm-router/`는 다섯
파일(router.py, spark-model, install-llm-router.sh, env.example, README.md)뿐이고 `tests/`·`spark/`는
포함되지 않는다(Spark 컨트롤러는 Spark에서 이 저장고로 설치).

**오프라인 설치:**
- Mac 쪽은 이미 네트워크 없이 설치된다.
  - 라우터는 `~/.guardian-llm/venv`(merged bundle에 fastapi·httpx·uvicorn 포함)의 python으로 돈다.
  - pip 등 추가 내려받기가 없다.
- DGX 쪽(k3s·vLLM/device plugin 이미지·모델·컨트롤러)은 이 kit에 들어 있지 않다.
  - 인터넷이 되는 arm64 호스트에서 `spark/pack-spark-offline.sh`로 묶음을 만든다.
  - 오프라인 DGX에서 `install-spark-offline.sh --bundle DIR`로 설치한다.
  - 자세한 내용은 `spark/README.md`의 "오프라인 설치"와 `docs/internal/SPARK-K8S-DESIGN.md` §5.1에 있다.

- python은 fastapi/httpx/uvicorn가 import되는 `~/.guardian-llm/venv/bin/python` (`--python=`로 변경)
- 설치물: `~/.guardian-llm/llm-router/router.py`, `~/.config/llm-router/env`(최초 1회 생성),
  `~/.local/bin/spark-model`(755), `~/Library/LaunchAgents/dev.guardian.llm-router.plist`(600,
  비밀 없음 — env 파일은 라우터가 읽는다)
- 직접 실행: `python guardian/llm-router/router.py`
- 테스트: `python3 -m unittest discover -s guardian/llm-router/tests -v`

## 알아둘 것

- `gui/501` 도메인의 LaunchAgent는 **화면 로그인 후에야 뜬다**. 재부팅 직후 로그인 전에는 라우터가
  없고, `claude-lms`는 이 경우 LM Studio 직접 연결로 자동 폴백한다.
- Host 헤더가 라우터의 루프백 주소(127.0.0.1 / localhost / [::1] + 포트)가 아니면 403으로 거부한다
  (브라우저 DNS 리바인딩 방지).
- 브라우저 발 요청 2중 방어: Origin 헤더가 붙어 있으면(브라우저의 cross-origin POST는 항상 붙고,
  Claude Code 같은 CLI/SDK는 안 붙는다) 그 host도 루프백이어야 하고(403), POST는 Content-Type이
  `application/json`(charset 등 파라미터는 무시)이어야 한다(415). 악성 웹페이지가 CORS preflight
  없이 보낼 수 있는 `text/plain` POST로는 `POST /v1/spark/switch`를 포함해 그 무엇도 할 수 없다.
  GET `/health` `/v1/models` `/v1/spark/status`는 Content-Type 없이 그대로 동작한다.
- claude-lms에서 `CLAUDE_LMS_ROUTER`를 설정하면 이 라우터를 경유한다(미설정 시 동작은 기존과 동일).
