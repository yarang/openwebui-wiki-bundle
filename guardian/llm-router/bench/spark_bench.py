#!/usr/bin/env python3
"""spark_bench.py — vLLM(OpenAI 호환) / llm-router(Anthropic) 부하 벤치마크 CLI.

DGX Spark 에서 학생 수십 명이 동시에 사용할 때의 운영 한계(동시성, TTFT,
디코딩 속도, KV 캐시, 선점 발생 등)를 측정한다.

사용 예:
    python spark_bench.py --base-url http://HOST:8000 --model NAME --out results.json
    # Claude Code → llm-router(Anthropic API) → vLLM 실경로 측정:
    python spark_bench.py --api anthropic --base-url http://127.0.0.1:1242 \
        --model spark-large --metrics-url http://SPARK:8000 \
        --tokenize-model qwen3-instruct --no-request-auth --require-route spark \
        --out out.json

API 키는 오직 환경변수 VLLM_API_KEY 로만 읽으며, 결과 JSON / 로그 / 예외
메시지 어디에도 기록하지 않는다. --no-request-auth 시 스트리밍 요청에는
Authorization 헤더를 실어 보내지 않는다(라우터가 백엔드 키를 주입).
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import json
import math
import os
import platform
import random
import re
import shlex
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional, Sequence

import httpx

IDLE_TIMEOUT_S = 120.0
IDLE_POLL_S = 1.0
SAMPLE_INTERVAL_S = 1.0
PROMPT_HEADROOM = 64
PHASE_ORDER = ("baseline", "sweep", "longctx", "burst", "shared")

INSTRUCTION = "위 글을 한국어로 자세히 요약하라."
Q_TEMPLATE = "질문: 위 내용을 한국어로 자세히 요약하라."
ASSIGN_HEAD = "과제:"

WORDS = [
    "spark", "dgx", "cluster", "compute", "memory", "bandwidth", "kernel",
    "tensor", "queue", "throughput", "latency", "student", "classroom",
    "lecture", "assignment", "summary", "question", "answer", "teacher",
    "campus", "network", "nvlink", "fabric", "unified", "capacity",
    "workload", "scheduler", "batching", "prefill", "decode", "context",
    "window", "token", "vocab", "embedding", "attention", "layer", "weight",
    "optimizer", "gradient", "checkpoint", "epoch", "loss", "metric",
    "sample", "dataset", "corpus", "document", "paragraph", "sentence",
    "chapter", "notebook", "server", "engine", "runtime", "cache", "prefix",
    "block",
]

M_RUNNING = "vllm:num_requests_running"
M_WAITING = "vllm:num_requests_waiting"
M_KV = "vllm:kv_cache_usage_perc"
M_KV_FALLBACK = "vllm:gpu_cache_usage_perc"
M_PREEMPT = "vllm:num_preemptions_total"
M_SUCCESS = "vllm:request_success_total"

Item = tuple[dict[str, Any], float, float]
Clock = Callable[[], float]


def _r(value: Optional[float], ndigits: int) -> Optional[float]:
    """None 이면 None, 아니면 반올림."""
    return None if value is None else round(value, ndigits)


def percentile(values: Sequence[float], p: float) -> Optional[float]:
    """선형 보간 백분위수. 비어 있으면 None."""
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return float(ordered[0])
    rank = (len(ordered) - 1) * (p / 100.0)
    lo, hi = math.floor(rank), math.ceil(rank)
    if lo == hi:
        return float(ordered[lo])
    return float(ordered[lo] * (hi - rank) + ordered[hi] * (rank - lo))


def short_error(exc: BaseException) -> str:
    """예외를 짧은 문자료로. 헤더/키가 포함되지 않는 형태만 사용한다."""
    msg = " ".join(str(exc).split())[:120]
    return f"{type(exc).__name__}: {msg}" if msg else type(exc).__name__


def parse_prometheus_text(text: str) -> dict[str, float]:
    """Prometheus 텍스트를 파싱해 이름별(라벨셋 합산) 합계를 반환."""
    out: dict[str, float] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name_part, _sep, value_part = line.rpartition(" ")
        if not name_part:
            continue
        try:
            value = float(value_part)
        except ValueError:
            continue
        name = name_part.split("{", 1)[0].strip()
        out[name] = out.get(name, 0.0) + value
    return out


def parse_labels(name_part: str) -> dict[str, str]:
    """`metric{a="1",b="2"}` 에서 라벨 dict 추출."""
    if "{" not in name_part:
        return {}
    start = name_part.index("{") + 1
    end = name_part.rindex("}") if "}" in name_part else len(name_part)
    return dict(re.findall(r'(\w+)="([^"]*)"', name_part[start:end]))


def extract_cache_config_info(text: str) -> dict[str, str]:
    for raw in text.splitlines():
        if raw.strip().startswith("vllm:cache_config_info"):
            return parse_labels(raw.strip())
    return {}


def pick_metric(parsed: dict[str, float], name: str) -> Optional[float]:
    if name in parsed:
        return parsed[name]
    if name == M_KV:
        return parsed.get(M_KV_FALLBACK)
    return None


def parse_gpu_line(line: str) -> Optional[dict[str, Optional[float]]]:
    """nvidia-smi CSV 한 줄(temp,power,sm_clock,util) 파싱. [N/A] 는 None."""
    parts = [p.strip() for p in line.strip().split(",")]
    if len(parts) < 4:
        return None

    def num(part: str) -> Optional[float]:
        if part in ("", "N/A", "[N/A]", "[Not Supported]"):
            return None
        try:
            return float(part)
        except ValueError:
            return None

    temp, power, clock, util = (num(p) for p in parts[:4])
    return {"temp_c": temp, "power_w": power, "sm_clock_mhz": clock, "util_pct": util}


def new_nonce() -> str:
    return f"[req {uuid.uuid4().hex[:6]}]"


def filler_words(n: int, rng: random.Random) -> str:
    return " ".join(rng.choice(WORDS) for _ in range(n))


def make_unique_prompt(target_tokens: float, tp_word: float, rng: random.Random) -> str:
    """nonce(맨 앞) + 필러 + 지시문. nonce 가 맨 앞이라 prefix cache 무효화."""
    nonce = new_nonce()
    total_words = max(8, round(target_tokens / tp_word)) if tp_word > 0 else 8
    filler = max(0, total_words - len(nonce.split()) - len(INSTRUCTION.split()))
    return f"{nonce}\n{filler_words(filler, rng)}\n{INSTRUCTION}"


def shared_mode_prompt(
    mode: str, assignment: str, total_words: int, rng: random.Random
) -> str:
    """shared: 공통 과제문(앞) + 유니크 질문(nonce 뒤). unique: nonce 앞 + 동일 길이."""
    nonce = new_nonce()
    if mode == "shared":
        return f"{assignment}\n{Q_TEMPLATE} {nonce}"
    filler = max(0, total_words - len(nonce.split()) - len(INSTRUCTION.split()))
    return f"{nonce}\n{filler_words(filler, rng)}\n{INSTRUCTION}"


def clamp_prompt_tokens(target: int, max_tokens: int, max_model_len: int) -> int:
    """prompt_tokens + max_tokens <= max_model_len - 64 가 되도록 감소."""
    budget = max_model_len - PROMPT_HEADROOM - max_tokens
    return max(16, min(target, budget))


async def calibrate(
    client: httpx.AsyncClient, model: str, headers: dict[str, str]
) -> tuple[float, bool]:
    """/tokenize 로 단어당 토큰수 측정. 실패 시 1.3 토큰/단어 폴백."""
    rng = random.Random(1234)
    sample = filler_words(2000, rng)
    try:
        resp = await client.post(
            "/tokenize", json={"model": model, "prompt": sample}, headers=headers
        )
        resp.raise_for_status()
        body = resp.json()
        count = body.get("count")
        if count is None and isinstance(body.get("tokens"), list):
            count = len(body["tokens"])
        if not isinstance(count, (int, float)) or count <= 0:
            raise ValueError("invalid tokenize count")
        return float(count) / len(sample.split()), False
    except Exception:
        return 1.3, True


def new_record() -> dict[str, Any]:
    return {
        "ok": False,
        "status": None,
        "error": None,
        "route": None,
        "ttft": None,
        "e2e": None,
        "prompt_tokens": None,
        "completion_tokens": None,
        "decode_tps": None,
    }


def chat_payload(model: str, prompt: str, max_tokens: int) -> dict[str, Any]:
    return {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "ignore_eos": True,
    }


def messages_payload(model: str, prompt: str, max_tokens: int) -> dict[str, Any]:
    """Anthropic /v1/messages 스트리밍 페이로드."""
    return {
        "model": model,
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "messages": [{"role": "user", "content": prompt}],
        "ignore_eos": True,
    }


def parse_sse_line(line: str) -> Optional[dict[str, Any]]:
    """`data: {...}` 파싱. [DONE] 은 {"__done__": True}, 무의미한 줄은 None."""
    if not line.startswith("data:"):
        return None
    data = line[len("data:"):].strip()
    if data == "[DONE]":
        return {"__done__": True}
    try:
        obj = json.loads(data)
    except (ValueError, TypeError):
        return None
    return obj if isinstance(obj, dict) else None


def _finish_record(
    rec: dict[str, Any],
    t_start: float,
    t_first: Optional[float],
    t_last: Optional[float],
    t_end: float,
) -> dict[str, Any]:
    rec["e2e"] = _r((t_last if t_last is not None else t_end) - t_start, 6)
    if t_first is not None:
        rec["ttft"] = _r(t_first - t_start, 6)
    tokens = rec.get("completion_tokens")
    if (
        t_first is not None
        and t_last is not None
        and isinstance(tokens, (int, float))
        and tokens > 1
        and t_last > t_first
    ):
        rec["decode_tps"] = round((tokens - 1) / (t_last - t_first), 3)
    return rec


async def stream_chat(
    client: httpx.AsyncClient,
    model: str,
    prompt: str,
    max_tokens: int,
    headers: dict[str, str],
    clock: Clock = time.perf_counter,
    require_route: Optional[str] = None,
) -> Item:
    """스트리밍 chat completion 1건. (record, t_start, t_end) 반환.

    청크 개수를 세지 않고 오직 마지막 usage 청크의 토큰수만 사용한다.
    """
    rec = new_record()
    t_first: Optional[float] = None
    t_last: Optional[float] = None
    usage: Optional[dict[str, Any]] = None
    t_start = clock()
    try:
        async with client.stream(
            "POST", "/v1/chat/completions", json=chat_payload(model, prompt, max_tokens),
            headers=headers,
        ) as resp:
            rec["status"] = resp.status_code
            rec["route"] = resp.headers.get("x-route")
            if resp.status_code != 200:
                rec["error"] = f"http_{resp.status_code}"
            else:
                async for line in resp.aiter_lines():
                    obj = parse_sse_line(line)
                    if obj is None:
                        continue
                    if obj.get("__done__"):
                        break
                    if isinstance(obj.get("usage"), dict):
                        usage = obj["usage"]
                    t_first, t_last = _scan_content(obj, clock, t_first, t_last)
                rec = _apply_usage(rec, usage)
    except Exception as exc:  # 연결 오류 등: 짧은 이유만 기록
        rec["ok"] = False
        rec["error"] = short_error(exc)
    rec = _check_route(rec, require_route)
    t_end = clock()
    return _finish_record(rec, t_start, t_first, t_last, t_end), t_start, t_end


def _scan_content(
    obj: dict[str, Any], clock: Clock, t_first: Optional[float], t_last: Optional[float]
) -> tuple[Optional[float], Optional[float]]:
    choices = obj.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        return t_first, t_last
    delta = choices[0].get("delta")
    content = delta.get("content") if isinstance(delta, dict) else None
    if isinstance(content, str) and content:
        now = clock()
        return (now if t_first is None else t_first), now
    return t_first, t_last


def _apply_usage(rec: dict[str, Any], usage: Optional[dict[str, Any]]) -> dict[str, Any]:
    if usage is None:
        rec["ok"] = False
        rec["error"] = "no_usage"
        return rec
    rec["ok"] = True
    rec["prompt_tokens"] = usage.get("prompt_tokens")
    rec["completion_tokens"] = usage.get("completion_tokens")
    return rec


def _check_route(rec: dict[str, Any], require_route: Optional[str]) -> dict[str, Any]:
    """--require-route 검증: 200 응답의 x-route 가 기대값과 다르면 실패 처리.

    스트림은 이미 끝까지 읽었으므로(drain) usage/시각 정보는 그대로 두고
    ok/error 만 바꾼다. 라우터를 우회한 응답은 집계에서 제외하기 위함.
    """
    if require_route is None or rec.get("status") != 200:
        return rec
    if rec.get("route") != require_route:
        rec["ok"] = False
        rec["error"] = f"route_mismatch:{rec.get('route')}"
    return rec


def _stamp_text_delta(
    obj: dict[str, Any], clock: Clock, t_first: Optional[float], t_last: Optional[float]
) -> tuple[Optional[float], Optional[float]]:
    """Anthropic content_block_delta(text_delta) 의 첫/마지막 토큰 시각 기록.

    _scan_content(OpenAI) 와 동일한 역할: 빈 텍스트/비텍스트 delta 는 무시.
    """
    delta = obj.get("delta")
    if not isinstance(delta, dict) or delta.get("type") != "text_delta":
        return t_first, t_last
    text = delta.get("text")
    if not (isinstance(text, str) and text):
        return t_first, t_last
    now = clock()
    return (now if t_first is None else t_first), now


def _apply_message_usage(
    rec: dict[str, Any], input_tokens: Any, output_tokens: Any
) -> dict[str, Any]:
    """Anthropic usage 반영. output_tokens 를 모르면 no_usage(sse_error 가 우선)."""
    if rec.get("error") == "sse_error":
        rec["ok"] = False
        return rec
    if not isinstance(output_tokens, (int, float)):
        rec["ok"] = False
        rec["error"] = "no_usage"
        return rec
    rec["ok"] = True
    rec["error"] = None
    rec["prompt_tokens"] = input_tokens
    rec["completion_tokens"] = output_tokens
    return rec


async def stream_messages(
    client: httpx.AsyncClient,
    model: str,
    prompt: str,
    max_tokens: int,
    headers: dict[str, str],
    clock: Clock = time.perf_counter,
    require_route: Optional[str] = None,
) -> Item:
    """스트리밍 Anthropic /v1/messages 1건. (record, t_start, t_end) 반환.

    `event:` 줄은 무시하고 data JSON 의 type 필드로 분기한다. 토큰수는
    message_start/message_delta 의 usage 만 사용한다(stream_chat 과 동일 집계).
    """
    rec = new_record()
    t_first: Optional[float] = None
    t_last: Optional[float] = None
    input_tokens: Any = None
    output_tokens: Any = None
    t_start = clock()
    try:
        async with client.stream(
            "POST", "/v1/messages", json=messages_payload(model, prompt, max_tokens),
            headers={**headers, "anthropic-version": "2023-06-01"},
        ) as resp:
            rec["status"] = resp.status_code
            rec["route"] = resp.headers.get("x-route")
            if resp.status_code != 200:
                rec["error"] = f"http_{resp.status_code}"
            else:
                async for line in resp.aiter_lines():
                    obj = parse_sse_line(line)
                    if obj is None:
                        continue
                    if obj.get("__done__"):
                        break
                    kind = obj.get("type")
                    if kind == "message_start":
                        message = obj.get("message")
                        usage = message.get("usage") if isinstance(message, dict) else None
                        if isinstance(usage, dict) and usage.get("input_tokens") is not None:
                            input_tokens = usage["input_tokens"]
                    elif kind == "content_block_delta":
                        t_first, t_last = _stamp_text_delta(obj, clock, t_first, t_last)
                    elif kind == "message_delta":
                        usage = obj.get("usage")
                        if isinstance(usage, dict):
                            if usage.get("output_tokens") is not None:
                                output_tokens = usage["output_tokens"]
                            if usage.get("input_tokens") is not None:  # 있으면 덮어쓴다
                                input_tokens = usage["input_tokens"]
                    elif kind == "message_stop":
                        break
                    elif kind == "error":
                        rec["ok"] = False
                        rec["error"] = "sse_error"
                rec = _apply_message_usage(rec, input_tokens, output_tokens)
    except Exception as exc:  # 연결 오류 등: 짧은 이유만 기록
        rec["ok"] = False
        rec["error"] = short_error(exc)
    rec = _check_route(rec, require_route)
    t_end = clock()
    return _finish_record(rec, t_start, t_first, t_last, t_end), t_start, t_end


def summarize_requests(requests: Sequence[dict[str, Any]], wall_s: float) -> dict[str, Any]:
    ok = [r for r in requests if r.get("ok")]
    ttfts = [r["ttft"] for r in ok if r.get("ttft") is not None]
    decodes = [r["decode_tps"] for r in ok if r.get("decode_tps") is not None]
    e2es = [r["e2e"] for r in ok if r.get("e2e") is not None]
    total_out = sum(r.get("completion_tokens") or 0 for r in ok)
    n_err = len(requests) - len(ok)
    routes: dict[str, int] = {}
    for r in requests:
        route = r.get("route")
        key = route if isinstance(route, str) and route else "none"
        routes[key] = routes.get(key, 0) + 1
    return {
        "n": len(requests),
        "ok": len(ok),
        "errors": n_err,
        "error_rate": round(n_err / len(requests), 4) if requests else None,
        "routes": routes,
        "wall_s": _r(wall_s, 3),
        "agg_output_tps": round(total_out / wall_s, 2) if wall_s > 0 and total_out else None,
        "ttft_p50": _r(percentile(ttfts, 50), 4),
        "ttft_p95": _r(percentile(ttfts, 95), 4),
        "ttft_max": _r(max(ttfts) if ttfts else None, 4),
        "decode_tps_p50": _r(percentile(decodes, 50), 2),
        "decode_tps_p10": _r(percentile(decodes, 10), 2),
        "decode_tps_min": _r(min(decodes) if decodes else None, 2),
        "e2e_p50": _r(percentile(e2es, 50), 4),
        "e2e_p95": _r(percentile(e2es, 95), 4),
    }


def window_of(samples: Sequence[dict[str, Any]], t0: float, t1: float) -> list[dict[str, Any]]:
    return [s for s in samples if s.get("t") is not None and t0 <= s["t"] <= t1]


def _max_key(samples: Sequence[dict[str, Any]], key: str) -> Optional[float]:
    vals = [s[key] for s in samples if s.get(key) is not None]
    return max(vals) if vals else None


def summarize_window(
    samples: Sequence[dict[str, Any]], gpu_samples: Sequence[dict[str, Any]], t0: float, t1: float
) -> dict[str, Any]:
    ms = window_of(samples, t0, t1)
    gs = window_of(gpu_samples, t0, t1)
    clocks = [g["sm_clock_mhz"] for g in gs if g.get("sm_clock_mhz") is not None]
    return {
        "max_running": _max_key(ms, "running"),
        "max_waiting": _max_key(ms, "waiting"),
        "max_kv_usage": _max_key(ms, "kv"),
        "gpu_max_temp_c": _max_key(gs, "temp_c"),
        "gpu_max_power_w": _max_key(gs, "power_w"),
        "gpu_min_sm_clock_mhz": min(clocks) if clocks else None,
    }


def probe_delta(
    pre: Optional[dict[str, Any]], post: Optional[dict[str, Any]], key: str
) -> Optional[float]:
    if not pre or not post or pre.get(key) is None or post.get(key) is None:
        return None
    return _r(post[key] - pre[key], 3)


def write_json_atomic(path: Path, obj: Any) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def print_step_line(phase: str, step: dict[str, Any]) -> None:
    print(
        f"[{phase}] {step.get('step', '')}: n={step.get('n')} "
        f"err={step.get('errors')}({step.get('error_rate')}) "
        f"ttft p50={step.get('ttft_p50')}s p95={step.get('ttft_p95')}s "
        f"dec p50={step.get('decode_tps_p50')} p10={step.get('decode_tps_p10')} "
        f"agg={step.get('agg_output_tps')}tok/s "
        f"wait={step.get('max_waiting')} kv={step.get('max_kv_usage')}",
        flush=True,
    )


class Bench:
    """1회 실행 상태. 전역 가변 상태는 없고 인스턴스만 사용한다."""

    def __init__(
        self,
        client: httpx.AsyncClient,
        args: argparse.Namespace,
        metrics_client: Optional[httpx.AsyncClient] = None,
    ) -> None:
        self.client = client
        # metrics/admin(/metrics,/tokenize,/v1/models,/version) 전용 클라이언트.
        # --metrics-url 미지정 시 요청과 같은 클라이언트(=같은 base_url)를 쓴다.
        self.metrics_client = metrics_client or client
        self.args = args
        api_key = os.environ.get("VLLM_API_KEY") or None
        auth = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        # metrics/admin 은 항상 vLLM 키. 스트리밍 요청은 --no-request-auth 면
        # 키 없이 보낸다(라우터가 백엔드 키를 주입).
        self.metrics_headers = auth
        self.headers = {} if args.no_request_auth else auth
        self.out_path = Path(args.out)
        self.t0 = time.perf_counter()
        self.tp_word = 1.3
        self.calib_fallback = True
        self.idle_timeout_s = IDLE_TIMEOUT_S
        self.rng = random.Random(20260212)
        self.samples: list[dict[str, Any]] = []
        self.gpu_samples: list[dict[str, Any]] = []
        self.gpu_error: Optional[str] = None
        self._stop = asyncio.Event()
        self._tasks: list[asyncio.Task[None]] = []
        self._gpu_proc: Optional[asyncio.subprocess.Process] = None
        self.results: dict[str, Any] = {
            "meta": {
                "started_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "base_url": args.base_url,
                "metrics_url": args.metrics_url,
                "model": args.model,
                "args": dict(vars(args)),
                "host": {"platform": platform.platform(), "python": platform.python_version()},
            },
            "server": {},
            "phases": {},
        }

    def now(self) -> float:
        return time.perf_counter() - self.t0

    def deadline_exceeded(self) -> bool:
        return self.now() >= self.args.max_minutes * 60.0

    def write(self) -> None:
        write_json_atomic(self.out_path, self.results)

    async def probe_metrics(self) -> Optional[dict[str, Any]]:
        """/metrics 1회 조회를 정규화된 게이지 dict 로. 실패 시 None."""
        try:
            resp = await self.metrics_client.get("/metrics", headers=self.metrics_headers)
            resp.raise_for_status()
            parsed = parse_prometheus_text(resp.text)
        except Exception:
            return None
        return {
            "running": pick_metric(parsed, M_RUNNING),
            "waiting": pick_metric(parsed, M_WAITING),
            "kv": pick_metric(parsed, M_KV),
            "preemptions": pick_metric(parsed, M_PREEMPT),
            "success": pick_metric(parsed, M_SUCCESS),
        }

    async def probe_and_record(self) -> tuple[float, Optional[dict[str, Any]]]:
        """경계 프로브: 결과를 시계열 samples 에도 남긴다(반올림 금지)."""
        t = self.now()
        metrics = await self.probe_metrics()
        if metrics is not None:
            self.samples.append({"t": t, **metrics})
        return t, metrics

    async def wait_idle(self) -> tuple[float, bool]:
        """num_requests_running==0 될 때까지 폴링. (대기시간, 타임아웃여부)."""
        start = self.now()
        while True:
            metrics = await self.probe_metrics()
            running = metrics.get("running") if metrics else None
            if running in (None, 0):
                return self.now() - start, False
            if self.now() - start >= self.idle_timeout_s:
                return self.now() - start, True
            await asyncio.sleep(IDLE_POLL_S)

    async def run_step(
        self,
        phase: str,
        label: str,
        launch: Callable[[], Awaitable[tuple[list[Item], dict[str, Any]]]],
    ) -> Optional[dict[str, Any]]:
        if self.deadline_exceeded():
            self.results["meta"]["stopped_early"] = "max_minutes exceeded"
            self.write()
            return None
        idle_s, idle_timeout = await self.wait_idle()
        t_pre, pre = await self.probe_and_record()
        items, extra = await launch()
        t_post, post = await self.probe_and_record()
        ordered = sorted(items, key=lambda it: it[1])
        requests = [rec for rec, _t0, _t1 in ordered]
        wall = self._wall_s(ordered, t_pre, t_post)
        summary = summarize_requests(requests, wall)
        summary.update(summarize_window(self.samples, self.gpu_samples, t_pre, t_post))
        summary.update(
            {
                "idle_wait_s": _r(idle_s, 3),
                "idle_timeout": idle_timeout,
                "preemptions_delta": probe_delta(pre, post, "preemptions"),
                "request_success_delta": probe_delta(pre, post, "success"),
            }
        )
        foreign = self._foreign_requests(summary)
        if foreign:
            summary["foreign_requests"] = foreign
        step = {
            "step": label,
            **summary,
            **extra,
            "requests": requests,
            "samples": window_of(self.samples, t_pre, t_post),
            "gpu": window_of(self.gpu_samples, t_pre, t_post),
        }
        self.results["phases"].setdefault(phase, {"steps": []})["steps"].append(step)
        self.write()
        print_step_line(phase, step)
        return step

    @staticmethod
    def _wall_s(ordered: Sequence[Item], t_pre: float, t_post: float) -> float:
        if not ordered:
            return t_post - t_pre
        return max(t1 for _r_, _t0, t1 in ordered) - min(t0 for _r_, t0, _t1 in ordered)

    @staticmethod
    def _foreign_requests(summary: dict[str, Any]) -> int:
        delta = summary.get("request_success_delta")
        if delta is None:
            return 0
        return max(0, int(delta - summary["ok"]))

    async def _metrics_loop(self) -> None:
        while True:
            t, metrics = await self.probe_and_record()
            if metrics is None:
                self.samples.append({"t": t, "error": "metrics_failed"})
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._stop.wait(), SAMPLE_INTERVAL_S)
                return

    async def _gpu_loop(self, proc: asyncio.subprocess.Process) -> None:
        if proc.stdout is None:
            return
        while True:
            raw = await proc.stdout.readline()
            if not raw:
                break
            parsed = parse_gpu_line(raw.decode("utf-8", "replace"))
            if parsed:
                parsed["t"] = _r(self.now(), 3)
                self.gpu_samples.append(parsed)

    async def _start_gpu(self) -> None:
        if not self.args.gpu_sample_cmd:
            return
        try:
            self._gpu_proc = await asyncio.create_subprocess_exec(
                *shlex.split(self.args.gpu_sample_cmd),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            self._tasks.append(asyncio.create_task(self._gpu_loop(self._gpu_proc)))
        except Exception as exc:
            self.gpu_error = f"{type(exc).__name__}: gpu sampler failed to start"
            self._gpu_proc = None

    async def _stop_gpu(self) -> None:
        if self._gpu_proc is not None and self._gpu_proc.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                self._gpu_proc.kill()
            with contextlib.suppress(Exception):
                await self._gpu_proc.wait()

    async def _fetch_server_info(self) -> None:
        server: dict[str, Any] = {}
        for key, path in (("models", "/v1/models"), ("version", "/version")):
            server[key] = await self._get_json(path)
        try:
            resp = await self.metrics_client.get("/metrics", headers=self.metrics_headers)
            server["cache_config_info"] = (
                extract_cache_config_info(resp.text) if resp.status_code == 200
                else {"error": f"http_{resp.status_code}"}
            )
        except Exception as exc:
            server["cache_config_info"] = {"error": type(exc).__name__}
        self.results["server"] = server

    async def _get_json(self, path: str) -> Any:
        try:
            resp = await self.metrics_client.get(path, headers=self.metrics_headers)
            resp.raise_for_status()
            try:
                return resp.json()
            except ValueError:
                return resp.text
        except Exception as exc:
            return {"error": type(exc).__name__}

    async def run(self) -> None:
        # 캘리브레이션(/tokenize) 은 vLLM 직통: 요청 모델이 라우터 별칭이면
        # --tokenize-model 의 실제 모델명으로 치환한다.
        tp_word, fallback = await calibrate(
            self.metrics_client,
            self.args.tokenize_model or self.args.model,
            self.metrics_headers,
        )
        self.tp_word, self.calib_fallback = tp_word, fallback
        self.results["meta"]["calibration"] = {
            "tokens_per_word": round(tp_word, 4),
            "fallback": fallback,
        }
        await self._fetch_server_info()
        await self._start_gpu()
        self._tasks.append(asyncio.create_task(self._metrics_loop()))
        self.write()
        dispatch: dict[str, Callable[[], Awaitable[None]]] = {
            "baseline": self.phase_baseline,
            "sweep": self.phase_sweep,
            "longctx": self.phase_longctx,
            "burst": self.phase_burst,
            "shared": self.phase_shared,
        }
        try:
            for name in self.args.phases:
                if self.deadline_exceeded():
                    self.results["meta"]["stopped_early"] = "max_minutes exceeded"
                    break
                await dispatch[name]()
        finally:
            await self._shutdown()

    async def _shutdown(self) -> None:
        self._stop.set()
        for task in self._tasks:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        await self._stop_gpu()
        if self.gpu_error:
            self.results["meta"]["gpu_sampler_error"] = self.gpu_error
        self.write()


    async def stream_one(self, prompt: str, max_tokens: int) -> Item:
        """--api 에 따라 OpenAI/Anthropic 스트리밍으로 분기하는 공통 진입점."""
        fn = stream_messages if self.args.api == "anthropic" else stream_chat
        return await fn(
            self.client, self.args.model, prompt, max_tokens, self.headers,
            require_route=self.args.require_route,
        )

    async def _barrier_requests(
        self, n: int, max_tokens: int, prompt_fn: Callable[[], str]
    ) -> list[Item]:
        """n개 요청을 모두 생성 뒤 게이트로 동시에 출발시킨다."""
        gate = asyncio.Event()

        async def one() -> Item:
            await gate.wait()
            return await self.stream_one(prompt_fn(), max_tokens)

        tasks = [asyncio.create_task(one()) for _ in range(n)]
        gate.set()
        return list(await asyncio.gather(*tasks))

    async def phase_baseline(self) -> None:
        args = self.args
        budget = clamp_prompt_tokens(200, 512, args.max_model_len)

        async def launch() -> tuple[list[Item], dict[str, Any]]:
            items: list[Item] = []
            for _i in range(3):
                prompt = make_unique_prompt(budget, self.tp_word, self.rng)
                items.append(await self.stream_one(prompt, 512))
            return items, {"concurrency": 1}

        await self.run_step("baseline", "baseline", launch)

    async def phase_sweep(self) -> None:
        args = self.args
        budget = clamp_prompt_tokens(
            args.sweep_prompt_tokens, args.sweep_max_tokens, args.max_model_len
        )
        aborted: Optional[str] = None
        for conc in args.concurrency:
            if aborted:
                break

            async def launch(conc: int = conc) -> tuple[list[Item], dict[str, Any]]:
                async def worker() -> list[Item]:
                    out: list[Item] = []
                    for _i in range(args.rounds):
                        prompt = make_unique_prompt(budget, self.tp_word, self.rng)
                        out.append(await self.stream_one(prompt, args.sweep_max_tokens))
                    return out

                gathered = await asyncio.gather(*(worker() for _ in range(conc)))
                return [item for sub in gathered for item in sub], {"concurrency": conc}

            step = await self.run_step("sweep", f"concurrency_{conc}", launch)
            if step is None:
                break
            aborted = self._sweep_abort_reason(step)
        if aborted:
            self.results["phases"].setdefault("sweep", {})["aborted_reason"] = aborted
            self.write()

    def _sweep_abort_reason(self, step: dict[str, Any]) -> Optional[str]:
        args = self.args
        if step["error_rate"] is not None and step["error_rate"] > args.abort_error_rate:
            return f"error_rate {step['error_rate']} > {args.abort_error_rate}"
        if step["ttft_p95"] is not None and step["ttft_p95"] > args.abort_p95_ttft:
            return f"ttft_p95 {step['ttft_p95']} > {args.abort_p95_ttft}"
        return None

    async def phase_longctx(self) -> None:
        args = self.args
        for target in args.longctx:
            budget = clamp_prompt_tokens(target, 64, args.max_model_len)

            async def launch(
                budget: int = budget, target: int = target
            ) -> tuple[list[Item], dict[str, Any]]:
                prompt = make_unique_prompt(budget, self.tp_word, self.rng)
                item = await self.stream_one(prompt, 64)
                rec = item[0]
                prefill = None
                if rec["ok"] and rec["ttft"] and rec["prompt_tokens"]:
                    prefill = round(rec["prompt_tokens"] / rec["ttft"], 1)
                rec["prefill_tps"] = prefill
                extra = {
                    "target_tokens": target,
                    "prompt_budget_tokens": budget,
                    "actual_prompt_tokens": rec["prompt_tokens"],
                    "prefill_tps": prefill,
                }
                return [item], extra

            if await self.run_step("longctx", f"ctx_{target}", launch) is None:
                break

    async def phase_burst(self) -> None:
        args = self.args
        budget = clamp_prompt_tokens(300, args.burst_max_tokens, args.max_model_len)
        for n in args.burst:

            async def launch(n: int = n) -> tuple[list[Item], dict[str, Any]]:
                prompt_fn = lambda: make_unique_prompt(budget, self.tp_word, self.rng)  # noqa: E731
                items = await self._barrier_requests(n, args.burst_max_tokens, prompt_fn)
                ttfts = [rec["ttft"] for rec, _t0, _t1 in items if rec["ok"] and rec["ttft"] is not None]
                e2es = [rec["e2e"] for rec, _t0, _t1 in items if rec["ok"] and rec["e2e"] is not None]
                extra = {
                    "n": n,
                    "time_until_all_started_streaming": _r(max(ttfts), 6) if ttfts else None,
                    "time_until_all_done": _r(max(e2es), 6) if e2es else None,
                }
                return items, extra

            if await self.run_step("burst", f"burst_{n}", launch) is None:
                break

    async def phase_shared(self) -> None:
        args = self.args
        budget = clamp_prompt_tokens(
            args.shared_prefix_tokens, args.shared_max_tokens, args.max_model_len
        )
        total_words = max(8, round(budget / self.tp_word)) if self.tp_word > 0 else 8
        q_words = len(Q_TEMPLATE.split()) + 2  # + nonce 2단어
        assign_words = max(0, total_words - q_words - len(ASSIGN_HEAD.split()))
        assignment = ASSIGN_HEAD + " " + filler_words(assign_words, random.Random(777))
        for mode in ("shared", "unique"):

            async def launch(mode: str = mode) -> tuple[list[Item], dict[str, Any]]:
                prompt_fn = lambda: shared_mode_prompt(  # noqa: E731
                    mode, assignment, total_words, self.rng
                )
                items = await self._barrier_requests(args.shared_n, args.shared_max_tokens, prompt_fn)
                extra = {
                    "mode": mode,
                    "n": args.shared_n,
                    "prefix_target_tokens": args.shared_prefix_tokens,
                    "prompt_budget_tokens": budget,
                }
                return items, extra

            if await self.run_step("shared", mode, launch) is None:
                break


def parse_csv_ints(raw: str) -> list[int]:
    values = [int(x) for x in raw.split(",") if x.strip()]
    if not values:
        raise argparse.ArgumentTypeError("empty list")
    return values


def parse_phases(raw: str) -> list[str]:
    names = [x.strip() for x in raw.split(",") if x.strip()]
    unknown = [n for n in names if n not in PHASE_ORDER]
    if unknown or not names:
        raise argparse.ArgumentTypeError(f"unknown/empty phases: {unknown or raw}")
    return names


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="spark_bench",
        description="vLLM(OpenAI 호환) 부하 벤치마크 — DGX Spark 수업 운영 한계 측정용.",
    )
    parser.add_argument("--base-url", required=True, help="예: http://HOST:8000")
    parser.add_argument("--model", required=True, help="모델 이름")
    parser.add_argument("--out", required=True, help="결과 JSON 경로")
    parser.add_argument("--phases", type=parse_phases, default=list(PHASE_ORDER),
                        help="쉼표 구분: baseline,sweep,longctx,burst,shared")
    parser.add_argument("--concurrency", type=parse_csv_ints,
                        default=[1, 2, 4, 8, 16, 32, 64, 128])
    parser.add_argument("--rounds", type=int, default=2)
    parser.add_argument("--sweep-prompt-tokens", type=int, default=500)
    parser.add_argument("--sweep-max-tokens", type=int, default=256)
    parser.add_argument("--longctx", type=parse_csv_ints,
                        default=[1000, 4000, 16000, 32000, 60000])
    parser.add_argument("--max-model-len", type=int, default=65536)
    parser.add_argument("--burst", type=parse_csv_ints, default=[32, 64])
    parser.add_argument("--burst-max-tokens", type=int, default=512)
    parser.add_argument("--shared-n", type=int, default=32)
    parser.add_argument("--shared-prefix-tokens", type=int, default=3000)
    parser.add_argument("--shared-max-tokens", type=int, default=256)
    parser.add_argument("--gpu-sample-cmd", default=None,
                        help="예: 'ssh dgx-spark nvidia-smi ... -lms 1000'")
    parser.add_argument("--api", choices=("openai", "anthropic"), default="openai",
                        help="요청 API: openai=/v1/chat/completions, anthropic=/v1/messages")
    parser.add_argument("--require-route", default=None,
                        help="기대하는 응답 헤더 x-route 값. 200 인데 다르면 route_mismatch 실패 처리")
    parser.add_argument("--metrics-url", default=None,
                        help="/metrics,/tokenize,/v1/models,/version 전용 base URL(기본: --base-url)")
    parser.add_argument("--tokenize-model", default=None,
                        help="/tokenize 에 보낼 모델명(요청 모델이 라우터 별칭일 때 실제 vLLM 모델). 기본 --model")
    parser.add_argument("--no-request-auth", action="store_true",
                        help="스트리밍 요청에 Authorization 헤더 미포함(라우터가 백엔드 키 주입). "
                             "metrics 요청은 항상 VLLM_API_KEY 사용)")
    parser.add_argument("--max-minutes", type=float, default=45.0)
    parser.add_argument("--abort-error-rate", type=float, default=0.05)
    parser.add_argument("--abort-p95-ttft", type=float, default=60.0)
    return parser


def make_client(base_url: str, transport: Optional[httpx.BaseTransport] = None) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=base_url.rstrip("/"),
        transport=transport,  # type: ignore[arg-type]
        limits=httpx.Limits(max_connections=None, max_keepalive_connections=None),
        timeout=httpx.Timeout(None, connect=10.0),
    )


async def run_async(
    args: argparse.Namespace,
    transport: Optional[httpx.BaseTransport] = None,
    metrics_transport: Optional[httpx.BaseTransport] = None,
) -> None:
    """스트리밍 요청은 --base-url, metrics/admin 은 --metrics-url(지정 시) 클라이언트로."""
    async with make_client(args.base_url, transport) as client:
        if not args.metrics_url:
            await Bench(client, args).run()
            return
        async with make_client(args.metrics_url, metrics_transport) as metrics_client:
            await Bench(client, args, metrics_client).run()


def main(
    argv: Optional[Sequence[str]] = None,
    transport: Optional[httpx.BaseTransport] = None,
    metrics_transport: Optional[httpx.BaseTransport] = None,
) -> int:
    args = build_parser().parse_args(argv)
    try:
        asyncio.run(run_async(args, transport, metrics_transport))
        return 0
    except KeyboardInterrupt:
        print("interrupted: partial results were written", file=sys.stderr, flush=True)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
