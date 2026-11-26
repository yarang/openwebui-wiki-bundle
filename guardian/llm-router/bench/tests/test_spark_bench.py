#!/usr/bin/env python3
"""spark_bench 단위 테스트 — 네트워크 없이 httpx.MockTransport 가짜 vLLM 로 검증."""
from __future__ import annotations

import asyncio
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Optional

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import spark_bench  # noqa: E402


class FakeClock:
    def __init__(self, step: float) -> None:
        self.t = 0.0
        self.step = step

    def __call__(self) -> float:
        self.t += self.step
        return self.t


def metrics_text(state: Optional[dict[str, Any]] = None) -> str:
    state = state or {}
    succ = state.get("success", 0)
    if state.get("foreign") and succ > 0:
        succ += state["foreign"]
    return "\n".join([
        "# HELP vllm:num_requests_running gauge",
        f'vllm:num_requests_running{{model_name="m"}} {state.get("metrics_running", 0)}',
        f'vllm:num_requests_waiting{{model_name="m"}} {state.get("waiting", 0)}',
        "vllm:kv_cache_usage_perc 0.42",
        f"vllm:num_preemptions_total {state.get('preemptions', 0)}",
        f'vllm:request_success_total{{finish_reason="stop"}} {succ}',
        f'vllm:request_success_total{{finish_reason="length"}} 0',
        'vllm:cache_config_info{block_size="16",cache_dtype="auto",'
        'enable_prefix_caching="true"} 1.0',
    ]) + "\n"


def sse_body(prompt_words: int, max_tokens: int, include_usage: bool = True) -> bytes:
    chunks = min(max_tokens, 6)
    lines = [
        "data: " + json.dumps({"choices": [{"delta": {"content": f"w{i} "}}]})
        for i in range(chunks)
    ]
    if include_usage:
        usage = {"prompt_tokens": prompt_words * 2, "completion_tokens": chunks}
        lines.append("data: " + json.dumps({"choices": [{"delta": {}}], "usage": usage}))
    lines.append("data: [DONE]")
    return ("\n".join(lines) + "\n\n").encode()


def anthropic_sse_body(
    prompt_words: int,
    max_tokens: int,
    include_usage: bool = True,
    sse_error: bool = False,
    include_message_stop: bool = True,
) -> bytes:
    """Anthropic /v1/messages 용 가짜 SSE. 텍스트 델타 6개 + 무시해야 할 델타 2개."""
    chunks = min(max_tokens, 6)
    lines = [
        "event: message_start",
        "data: " + json.dumps({
            "type": "message_start",
            "message": {"usage": {"input_tokens": prompt_words * 2, "output_tokens": 1}},
        }),
        "event: content_block_start",
        "data: " + json.dumps({
            "type": "content_block_start", "index": 0,
            "content_block": {"type": "text", "text": ""},
        }),
    ]
    for i in range(chunks):
        lines.append("data: " + json.dumps({
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "text_delta", "text": f"w{i} "},
        }))
    # 빈 text_delta / 비텍스트 delta 는 시각 기록에서 제외되어야 한다.
    lines.append("data: " + json.dumps({
        "type": "content_block_delta", "index": 0,
        "delta": {"type": "text_delta", "text": ""},
    }))
    lines.append("data: " + json.dumps({
        "type": "content_block_delta", "index": 0,
        "delta": {"type": "thinking_delta", "thinking": "hmm"},
    }))
    lines.append("event: content_block_stop")
    lines.append("data: " + json.dumps({"type": "content_block_stop", "index": 0}))
    if sse_error:
        lines.append("event: error")
        lines.append("data: " + json.dumps({
            "type": "error",
            "error": {"type": "overloaded_error", "message": "overloaded"},
        }))
    if include_usage:
        lines.append("event: message_delta")
        lines.append("data: " + json.dumps({
            "type": "message_delta",
            "delta": {"stop_reason": "max_tokens"},
            "usage": {"output_tokens": chunks},
        }))
    if include_message_stop:
        lines.append("event: message_stop")
        lines.append("data: " + json.dumps({"type": "message_stop"}))
    lines.append("data: [DONE]")
    return ("\n".join(lines) + "\n\n").encode()


def stream_headers(state: dict[str, Any]) -> dict[str, str]:
    headers = {"content-type": "text/event-stream"}
    if state.get("x_route"):
        headers["x-route"] = state["x_route"]
    return headers


def make_transport(state: Optional[dict[str, Any]] = None) -> httpx.MockTransport:
    # caller 가 넘긴 dict 를 그대로 공유해 기록(tokenize_models 등)을 관찰하게 한다.
    state = state if state is not None else {}
    state.setdefault("success", 0)
    state.setdefault("seen_auth", [])

    async def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        auth = request.headers.get("authorization")
        state["seen_auth"].append((path, auth))
        if path == "/tokenize":
            if state.get("tokenize_fail"):
                return httpx.Response(500, json={"error": "boom"})
            body = json.loads(request.content)
            state.setdefault("tokenize_models", []).append(body.get("model"))
            n_words = len(body["prompt"].split())
            return httpx.Response(200, json={"count": n_words * 2})
        if path == "/v1/chat/completions":
            if state.get("fail_mode") == "http500":
                return httpx.Response(500, json={"error": "boom"})
            body = json.loads(request.content)
            prompt = body["messages"][0]["content"]
            include_usage = state.get("fail_mode") != "no_usage"
            state["success"] += 1
            return httpx.Response(
                200,
                headers=stream_headers(state),
                content=sse_body(len(prompt.split()), body["max_tokens"], include_usage),
            )
        if path == "/v1/messages":
            if state.get("fail_mode") == "http500":
                return httpx.Response(
                    500, json={"type": "error", "error": {"message": "boom"}}
                )
            body = json.loads(request.content)
            state.setdefault("messages_bodies", []).append(body)
            state.setdefault("seen_anthropic_version", []).append(
                request.headers.get("anthropic-version")
            )
            prompt = body["messages"][0]["content"]
            fail = state.get("fail_mode")
            state["success"] += 1
            return httpx.Response(
                200,
                headers=stream_headers(state),
                content=anthropic_sse_body(
                    len(prompt.split()),
                    body["max_tokens"],
                    include_usage=fail != "no_usage",
                    sse_error=fail == "sse_error",
                    include_message_stop=fail != "no_usage",  # no_usage: [DONE] 종료 검증
                ),
            )
        if path == "/metrics":
            return httpx.Response(200, text=metrics_text(state))
        if path == "/v1/models":
            return httpx.Response(200, json={"object": "list", "data": [{"id": "m"}]})
        if path == "/version":
            return httpx.Response(200, json={"version": "0.15.1"})
        return httpx.Response(404, json={"error": "not found"})

    return httpx.MockTransport(handler)


class PercentileTest(unittest.TestCase):
    def test_empty_and_single(self) -> None:
        self.assertIsNone(spark_bench.percentile([], 50))
        self.assertEqual(spark_bench.percentile([5], 95), 5.0)

    def test_interpolation(self) -> None:
        self.assertEqual(spark_bench.percentile([1, 2], 50), 1.5)
        self.assertEqual(spark_bench.percentile([1, 2, 3, 4], 25), 1.75)
        self.assertAlmostEqual(spark_bench.percentile(list(range(10)), 95), 8.55)


class ParseTest(unittest.TestCase):
    def test_prometheus_sums_over_label_sets(self) -> None:
        parsed = spark_bench.parse_prometheus_text(metrics_text({"success": 7}))
        self.assertEqual(parsed["vllm:request_success_total"], 7.0)
        self.assertEqual(parsed["vllm:num_requests_running"], 0.0)

    def test_kv_fallback(self) -> None:
        parsed = spark_bench.parse_prometheus_text(
            'vllm:gpu_cache_usage_perc 0.5\n'
        )
        self.assertEqual(spark_bench.pick_metric(parsed, spark_bench.M_KV), 0.5)
        self.assertIsNone(
            spark_bench.pick_metric({"vllm:gpu_cache_usage_perc": 0.5}, spark_bench.M_RUNNING)
        )

    def test_cache_config_info(self) -> None:
        info = spark_bench.extract_cache_config_info(metrics_text({}))
        self.assertEqual(info["block_size"], "16")
        self.assertEqual(info["enable_prefix_caching"], "true")

    def test_gpu_line(self) -> None:
        d = spark_bench.parse_gpu_line("38, 243.5, 1593, 92")
        self.assertEqual(d, {"temp_c": 38.0, "power_w": 243.5,
                             "sm_clock_mhz": 1593.0, "util_pct": 92.0})
        na = spark_bench.parse_gpu_line("[N/A], 243.5, [N/A], 92")
        self.assertIsNone(na["temp_c"])
        self.assertIsNone(na["sm_clock_mhz"])
        self.assertIsNone(spark_bench.parse_gpu_line("junk"))


class StreamChatTest(unittest.TestCase):
    def run_coro(self, coro: Any) -> Any:
        return asyncio.run(coro)

    def test_sse_math_with_fake_clock(self) -> None:
        transport = make_transport()

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return await spark_bench.stream_chat(
                    client, "m", "one two three four", 64, {}, clock=FakeClock(0.01)
                )

        rec, _t0, _t1 = self.run_coro(go())
        self.assertTrue(rec["ok"])
        self.assertEqual(rec["prompt_tokens"], 8)   # 4 words * 2
        self.assertEqual(rec["completion_tokens"], 6)  # usage 기반, 청크 수 아님
        self.assertAlmostEqual(rec["ttft"], 0.01, places=9)
        self.assertAlmostEqual(rec["e2e"], 0.06, places=9)
        self.assertAlmostEqual(rec["decode_tps"], (6 - 1) / 0.05, places=6)

    def test_http_500(self) -> None:
        transport = make_transport({"fail_mode": "http500"})

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return await spark_bench.stream_chat(client, "m", "hi", 64, {})

        rec, _t0, _t1 = self.run_coro(go())
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["status"], 500)
        self.assertEqual(rec["error"], "http_500")

    def test_no_usage(self) -> None:
        transport = make_transport({"fail_mode": "no_usage"})

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return await spark_bench.stream_chat(client, "m", "hi", 64, {})

        rec, _t0, _t1 = self.run_coro(go())
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["error"], "no_usage")


class StreamMessagesTest(unittest.TestCase):
    def run_coro(self, coro: Any) -> Any:
        return asyncio.run(coro)

    def _run(
        self,
        state: Optional[dict[str, Any]] = None,
        prompt: str = "one two three four",
        require_route: Optional[str] = None,
    ) -> spark_bench.Item:
        transport = make_transport(state)

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return await spark_bench.stream_messages(
                    client, "m", prompt, 64, {}, clock=FakeClock(0.01),
                    require_route=require_route,
                )

        return self.run_coro(go())

    def test_sse_math_with_fake_clock(self) -> None:
        # FakeClock(0.01): t_start=0.01, 텍스트 델타 6개가 0.02~0.07 에 도착.
        rec, _t0, _t1 = self._run({})
        self.assertTrue(rec["ok"])
        self.assertEqual(rec["prompt_tokens"], 8)      # message_start input_tokens
        self.assertEqual(rec["completion_tokens"], 6)  # message_delta output_tokens
        self.assertAlmostEqual(rec["ttft"], 0.01, places=9)
        self.assertAlmostEqual(rec["e2e"], 0.06, places=9)
        self.assertAlmostEqual(rec["decode_tps"], (6 - 1) / 0.05, places=6)

    def test_payload_and_version_header(self) -> None:
        state: dict[str, Any] = {}

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(
                transport=make_transport(state), base_url="http://t"
            ) as client:
                return await spark_bench.stream_messages(client, "m", "hello world", 32, {})

        self.run_coro(go())
        body = state["messages_bodies"][0]
        self.assertEqual(body["model"], "m")
        self.assertEqual(body["max_tokens"], 32)
        self.assertEqual(body["temperature"], 0)
        self.assertTrue(body["stream"])
        self.assertTrue(body["ignore_eos"])
        self.assertEqual(body["messages"], [{"role": "user", "content": "hello world"}])
        self.assertNotIn("stream_options", body)
        self.assertEqual(state["seen_anthropic_version"], ["2023-06-01"])

    def test_error_event_fails(self) -> None:
        rec, _t0, _t1 = self._run({"fail_mode": "sse_error"})
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["error"], "sse_error")

    def test_missing_usage_fails_and_done_terminates(self) -> None:
        # message_stop 없이 [DONE] 으로만 끝나는 스트림도 정상 종료되어야 한다.
        rec, _t0, _t1 = self._run({"fail_mode": "no_usage"})
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["error"], "no_usage")
        self.assertIsNone(rec["prompt_tokens"])
        self.assertIsNone(rec["completion_tokens"])

    def test_http_500(self) -> None:
        rec, _t0, _t1 = self._run({"fail_mode": "http500"})
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["status"], 500)
        self.assertEqual(rec["error"], "http_500")


class RouteTest(unittest.TestCase):
    def run_coro(self, coro: Any) -> Any:
        return asyncio.run(coro)

    def test_route_recorded_and_require_route(self) -> None:
        transport = make_transport({"x_route": "spark"})

        async def go() -> list[spark_bench.Item]:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return [
                    await spark_bench.stream_chat(client, "m", "hi", 64, {}),
                    await spark_bench.stream_chat(
                        client, "m", "hi", 64, {}, require_route="spark"
                    ),
                    await spark_bench.stream_chat(
                        client, "m", "hi", 64, {}, require_route="vllm"
                    ),
                ]

        items = self.run_coro(go())
        plain, matched, mismatched = (it[0] for it in items)
        self.assertEqual(plain["route"], "spark")
        self.assertTrue(plain["ok"])
        self.assertTrue(matched["ok"])
        self.assertFalse(mismatched["ok"])
        self.assertEqual(mismatched["error"], "route_mismatch:spark")
        self.assertEqual(mismatched["route"], "spark")
        # 스트림은 끝까지 읽었으므로(drain) usage 는 그대로 남는다.
        self.assertEqual(mismatched["completion_tokens"], 6)
        summary = spark_bench.summarize_requests([plain, matched, mismatched], 1.0)
        self.assertEqual(summary["routes"], {"spark": 3})

    def test_routes_none_without_header(self) -> None:
        transport = make_transport()

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return await spark_bench.stream_chat(client, "m", "hi", 64, {})

        rec, _t0, _t1 = self.run_coro(go())
        self.assertIsNone(rec["route"])
        self.assertTrue(rec["ok"])
        summary = spark_bench.summarize_requests([rec], 1.0)
        self.assertEqual(summary["routes"], {"none": 1})

    def test_mismatch_missing_header_reports_none(self) -> None:
        transport = make_transport()  # x-route 헤더 자체가 없음

        async def go() -> spark_bench.Item:
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                return await spark_bench.stream_chat(
                    client, "m", "hi", 64, {}, require_route="spark"
                )

        rec, _t0, _t1 = self.run_coro(go())
        self.assertFalse(rec["ok"])
        self.assertEqual(rec["error"], "route_mismatch:None")


class WaitIdleTest(unittest.TestCase):
    def test_timeout_flagged(self) -> None:
        transport = make_transport({"metrics_running": 2})

        async def go() -> tuple[float, bool]:
            args = spark_bench.build_parser().parse_args(
                ["--base-url", "http://t", "--model", "m", "--out", "/dev/null"]
            )
            async with httpx.AsyncClient(transport=transport, base_url="http://t") as client:
                bench = spark_bench.Bench(client, args)
                bench.idle_timeout_s = 0.2
                return await bench.wait_idle()

        waited, timed_out = self.run_coro(go())
        self.assertTrue(timed_out)
        self.assertGreaterEqual(waited, 0.15)

    def run_coro(self, coro: Any) -> Any:
        return asyncio.run(coro)


class MainRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.out = str(Path(self._tmp.name) / "results.json")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_main(
        self, extra: list[str], state: Optional[dict[str, Any]] = None
    ) -> tuple[int, dict[str, Any], str, str]:
        transport = make_transport(state)
        argv = ["--base-url", "http://fake", "--model", "m", "--out", self.out, *extra]
        out_buf, err_buf = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
            rc = spark_bench.main(argv, transport=transport)
        results = json.loads(Path(self.out).read_text(encoding="utf-8"))
        return rc, results, out_buf.getvalue(), err_buf.getvalue()

    def test_all_phases_structure(self) -> None:
        rc, results, stdout, _err = self.run_main([
            "--phases", "baseline,sweep,longctx,burst,shared",
            "--concurrency", "1,2", "--rounds", "1",
            "--longctx", "100", "--burst", "2", "--shared-n", "2",
            "--shared-prefix-tokens", "100",
        ])
        self.assertEqual(rc, 0)
        self.assertEqual(list(results["phases"]), PHASE_LIST)
        meta = results["meta"]
        self.assertIn("started_at", meta)
        self.assertEqual(meta["model"], "m")
        self.assertFalse(meta["calibration"]["fallback"])
        self.assertEqual(meta["calibration"]["tokens_per_word"], 2.0)
        server = results["server"]
        self.assertEqual(server["models"]["data"][0]["id"], "m")
        self.assertEqual(server["version"]["version"], "0.15.1")
        self.assertEqual(server["cache_config_info"]["block_size"], "16")
        for step in all_steps(results):
            for key in ("n", "ok", "errors", "error_rate", "wall_s", "agg_output_tps",
                        "ttft_p50", "ttft_p95", "decode_tps_p50", "decode_tps_p10",
                        "max_waiting", "max_kv_usage", "gpu_max_temp_c",
                        "requests", "samples", "gpu"):
                self.assertIn(key, step, f"{step['step']} missing {key}")
            self.assertGreaterEqual(len(step["samples"]), 2)  # pre/post 프로브
            for rec in step["requests"]:
                for key in ("ok", "status", "ttft", "e2e", "prompt_tokens",
                            "completion_tokens", "decode_tps"):
                    self.assertIn(key, rec)
        sweep = [s for s in results["phases"]["sweep"]["steps"]]
        self.assertEqual([s["concurrency"] for s in sweep], [1, 2])
        burst = results["phases"]["burst"]["steps"][0]
        self.assertIn("time_until_all_started_streaming", burst)
        self.assertIn("time_until_all_done", burst)
        shared_modes = [s["mode"] for s in results["phases"]["shared"]["steps"]]
        self.assertEqual(shared_modes, ["shared", "unique"])
        self.assertIn("baseline", stdout)

    def test_prompt_clamped_to_max_model_len(self) -> None:
        _rc, results, _o, _e = self.run_main([
            "--phases", "longctx", "--longctx", "100000", "--max-model-len", "512",
        ])
        step = results["phases"]["longctx"]["steps"][0]
        rec = step["requests"][0]
        self.assertEqual(step["prompt_budget_tokens"], 512 - 64 - 64)
        self.assertEqual(rec["prompt_tokens"], 384)  # 192 words * 2 tokens
        self.assertLessEqual(rec["prompt_tokens"] + 64, 512 - 64)
        self.assertIn("prefill_tps", step)

    def test_sweep_abort_on_error_rate(self) -> None:
        _rc, results, _o, _e = self.run_main([
            "--phases", "sweep", "--concurrency", "1,2,4", "--rounds", "1",
        ], state={"fail_mode": "http500"})
        sweep = results["phases"]["sweep"]
        self.assertEqual(len(sweep["steps"]), 1)
        self.assertIn("error_rate", sweep["aborted_reason"])
        self.assertEqual(sweep["steps"][0]["errors"], 1)

    def test_foreign_requests_detected(self) -> None:
        _rc, results, _o, _e = self.run_main(
            ["--phases", "baseline"], state={"foreign": 2}
        )
        step = results["phases"]["baseline"]["steps"][0]
        self.assertEqual(step["foreign_requests"], 2)

    def test_calibration_fallback(self) -> None:
        _rc, results, _o, _e = self.run_main(
            ["--phases", "baseline"], state={"tokenize_fail": True}
        )
        self.assertTrue(results["meta"]["calibration"]["fallback"])
        self.assertEqual(results["meta"]["calibration"]["tokens_per_word"], 1.3)

    def test_api_key_never_leaks(self) -> None:
        secret = "sk-SECRET-DO-NOT-PRINT-9f3ab2"
        old = os.environ.get("VLLM_API_KEY")
        os.environ["VLLM_API_KEY"] = secret
        try:
            _rc, results, stdout, stderr = self.run_main(["--phases", "baseline"])
        finally:
            if old is None:
                os.environ.pop("VLLM_API_KEY", None)
            else:
                os.environ["VLLM_API_KEY"] = old
        raw = Path(self.out).read_text(encoding="utf-8")
        self.assertNotIn(secret, raw)
        self.assertNotIn(secret, json.dumps(results, ensure_ascii=False))
        self.assertNotIn(secret, stdout)
        self.assertNotIn(secret, stderr)

    def test_openai_defaults_unchanged(self) -> None:
        _rc, results, _o, _e = self.run_main(["--phases", "baseline"])
        step = results["phases"]["baseline"]["steps"][0]
        self.assertEqual(step["ok"], 3)
        self.assertEqual(step["routes"], {"none": 3})
        self.assertIsNone(step["requests"][0]["route"])
        self.assertIsNone(results["meta"]["metrics_url"])
        self.assertEqual(results["meta"]["args"]["api"], "openai")
        self.assertFalse(results["meta"]["args"]["no_request_auth"])

    def test_anthropic_e2e_baseline(self) -> None:
        _rc, results, _o, _e = self.run_main(["--api", "anthropic", "--phases", "baseline"])
        step = results["phases"]["baseline"]["steps"][0]
        self.assertEqual(step["ok"], 3)
        self.assertEqual(step["errors"], 0)
        rec = step["requests"][0]
        # 캘리브레이션 2.0 tok/word × 프롬프트 100단어 = 200 input_tokens.
        self.assertEqual(rec["prompt_tokens"], 200)
        self.assertEqual(rec["completion_tokens"], 6)
        self.assertIsNotNone(rec["decode_tps"])
        self.assertEqual(step["routes"], {"none": 3})

    def test_require_route_in_main(self) -> None:
        _rc, results, _o, _e = self.run_main(
            ["--phases", "baseline", "--require-route", "spark"], state={"x_route": "spark"}
        )
        step = results["phases"]["baseline"]["steps"][0]
        self.assertEqual(step["ok"], 3)
        self.assertEqual(step["routes"], {"spark": 3})

        _rc, results, _o, _e = self.run_main(
            ["--phases", "baseline", "--require-route", "vllm"], state={"x_route": "spark"}
        )
        step = results["phases"]["baseline"]["steps"][0]
        self.assertEqual(step["ok"], 0)
        self.assertEqual(step["errors"], 3)
        self.assertEqual(step["routes"], {"spark": 3})
        self.assertEqual(step["requests"][0]["error"], "route_mismatch:spark")

    def test_metrics_url_split_transports_and_auth(self) -> None:
        secret = "sk-METRICS-ONLY-3f8e21"
        old = os.environ.get("VLLM_API_KEY")
        os.environ["VLLM_API_KEY"] = secret
        try:
            req_state: dict[str, Any] = {"x_route": "spark"}
            met_state: dict[str, Any] = {}
            argv = [
                "--base-url", "http://req", "--model", "m", "--out", self.out,
                "--phases", "baseline", "--api", "anthropic",
                "--metrics-url", "http://met", "--tokenize-model", "qwen3-instruct",
                "--no-request-auth", "--require-route", "spark",
            ]
            out_buf, err_buf = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
                rc = spark_bench.main(
                    argv,
                    transport=make_transport(req_state),
                    metrics_transport=make_transport(met_state),
                )
            self.assertEqual(rc, 0)
            # 스트리밍 요청은 --base-url(라우터) 로만 향한다.
            req_paths = {p for p, _a in req_state["seen_auth"]}
            self.assertEqual(req_paths, {"/v1/messages"})
            # metrics/admin 은 --metrics-url(vLLM 직통) 로만 향한다.
            met_paths = {p for p, _a in met_state["seen_auth"]}
            self.assertEqual(met_paths, {"/tokenize", "/metrics", "/v1/models", "/version"})
            # --no-request-auth: 요청 무인증, metrics 는 항상 vLLM 키.
            self.assertTrue(all(a is None for _p, a in req_state["seen_auth"]))
            self.assertTrue(all(a == f"Bearer {secret}" for _p, a in met_state["seen_auth"]))
            # 라우터 별칭이 아닌 실제 모델명으로 /tokenize 호출.
            self.assertEqual(met_state["tokenize_models"], ["qwen3-instruct"])
            results = json.loads(Path(self.out).read_text(encoding="utf-8"))
            self.assertEqual(results["meta"]["metrics_url"], "http://met")
            step = results["phases"]["baseline"]["steps"][0]
            self.assertEqual(step["ok"], 3)
            self.assertEqual(step["routes"], {"spark": 3})
            raw = Path(self.out).read_text(encoding="utf-8")
            self.assertNotIn(secret, raw)
            self.assertNotIn(secret, out_buf.getvalue())
            self.assertNotIn(secret, err_buf.getvalue())
        finally:
            if old is None:
                os.environ.pop("VLLM_API_KEY", None)
            else:
                os.environ["VLLM_API_KEY"] = old


PHASE_LIST = ["baseline", "sweep", "longctx", "burst", "shared"]


def all_steps(results: dict[str, Any]):
    for phase in results["phases"].values():
        yield from phase["steps"]


if __name__ == "__main__":
    unittest.main()