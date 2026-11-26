# spark_bench — DGX Spark vLLM 부하 벤치마크

vLLM(OpenAI 호환, 0.15.x) 서버에서 학생 수십 명 동시 사용 시 운영 한계를 측정하는 CLI.
`--api anthropic` + `--metrics-url` 조합으로 Claude Code → llm-router(Anthropic API)
→ vLLM 로 이어지는 실제 서비스 경로도 측정할 수 있다.

## 실행

```bash
python guardian/llm-router/bench/spark_bench.py \
    --base-url http://HOST:8000 --model MODEL_NAME --out results.json
```

API 키가 필요하면 환경변수로만 전달한다 (결과/로그에 절대 기록되지 않음):

```bash
VLLM_API_KEY=sk-... python .../spark_bench.py ...
```

GPU 온도/전력/클록 병행 수집(선택):

```bash
--gpu-sample-cmd "ssh dgx-spark nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.sm,utilization.gpu --format=csv,noheader,nounits -lms 1000"
```

## 실경로 측정 (Claude Code → llm-router → vLLM)

스트리밍 요청(`--api anthropic` = `POST /v1/messages`)은 라우터로 보내고,
metrics/admin(`/metrics`, `/tokenize`, `/v1/models`, `/version`)은 vLLM 직통
(`--metrics-url`)으로 분리한다. 라우터가 백엔드 키를 주입하므로 요청에는
Authorization 을 실어 보내지 않는다(`--no-request-auth`).

```bash
VLLM_API_KEY=... python spark_bench.py --api anthropic --base-url http://127.0.0.1:1242 --model spark-large \
    --metrics-url http://SPARK:8000 --tokenize-model qwen3-instruct --no-request-auth --require-route spark --out out.json
```

### 플래그

| 플래그 | 기본 | 설명 |
|---|---|---|
| `--api {openai,anthropic}` | `openai` | 요청 API. `anthropic` 은 `/v1/messages` SSE(`anthropic-version: 2023-06-01`), OpenAI 와 동일 집계 방식(usage 토큰수만 사용) |
| `--metrics-url URL` | `--base-url` | `/metrics`,`/tokenize`,`/v1/models`,`/version` 전용 base URL. 지정 시 클라이언트가 분리되고 meta 의 `metrics_url` 에 기록 |
| `--tokenize-model NAME` | `--model` | `/tokenize` 에 보낼 모델명. 요청 모델이 라우터 별칭(`spark-large` 등)이면 실제 vLLM 모델명을 지정 |
| `--no-request-auth` | off | 스트리밍 요청에 `Authorization` 미포함(라우터가 백엔드 키 주입). metrics 요청은 항상 `VLLM_API_KEY` 사용 — 키 값은 어디에도 출력/기록되지 않음 |
| `--require-route TEXT` | 없음 | 200 응답의 `x-route` 헤더가 TEXT 와 다르면 `route_mismatch:<값>` 실패로 기록(스트림은 끝까지 읽음). 라우터를 우회한 응답을 집계에서 걷어낸다 |

- 모든 요청 레코드에 응답 헤더 `x-route` 값이 `route` 로 남고(없으면 `null`),
  단계 요약에 `routes`: `{경로값 또는 "none": 개수}` 이 집계된다.
- Anthropic SSE 의 `error` 이벤트는 `sse_error`, usage 부재는 `no_usage` 로 기록된다.

## 페이즈 (기본 순서대로 전부 실행, `--phases` 로 선택)

| 페이즈 | 내용 |
|---|---|
| `baseline` | 순차 3요청 (프롬프트 ~200토큰, max 512) — 정상 확인 |
| `sweep` | 동시성별 c 워커 × `--rounds` 회 연속 요청 → 한계 동시성 탐색 |
| `longctx` | 긴 프롬프트 순차 1요청 (max 64) → prefill tps, KV 사용률 |
| `burst` | N개 동시 일제히 출발 → 전원 스트리밍 시작/종료 시각 |
| `shared` | 동일 접두어(과제문) vs 유니크 프롬프트 비교 → prefix cache 효과 |

각 단계 전 서버 유휴 대기(running==0), 후 외부 요청 감지. sweep 는 오류율/TTFT 임계
초과 시 남은 단계 중단(`aborted_reason` 기록). `--max-minutes` 초과 시 이후 단계 생략.
결과 JSON 은 단계마다 원자적(tmp+rename)으로 기록되어 크래시/Ctrl-C 에도 부분 데이터 유지.

## 테스트

```bash
python -m unittest discover -s guardian/llm-router/bench/tests -v
```
