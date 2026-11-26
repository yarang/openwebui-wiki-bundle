"""Tests for router.py, against faked LM Studio and Spark upstreams.

Run with the target venv's python (needs fastapi/httpx/uvicorn):
    python3 -m unittest discover -s guardian/llm-router/tests -v
"""

import asyncio
import gzip
import json
import logging
import os
import resource
import sys
import tempfile
import unittest
from contextlib import asynccontextmanager
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import httpx

import router

LOCAL_HOST, LOCAL_PORT = "127.0.0.1", 1234
SPARK_HOST, SPARK_PORT = "172.30.1.35", 8000
SPARK2_HOST, SPARK2_PORT = "172.30.1.36", 8001  # a second vLLM instance on the Spark, own URL
KEY = "test-spark-key-123"
SWITCH_HOST, SWITCH_PORT = "172.30.1.35", 8010  # the spark-switch controller, same box, own port
SWITCH_TOKEN = "test-switch-token-456"

GEMMA = {"id": "google/gemma-4-e4b", "max_model_len": 65536}
QWEN = {"id": "qwen3-coder", "max_model_len": 131072, "root": "/models/qwen3-coder"}
QWEN_INSTRUCT = {"id": "qwen3-instruct", "max_model_len": 131072, "root": "/models/qwen3-instruct"}
GPT_OSS = {"id": "gpt-oss-120b", "max_model_len": 131072, "root": "/models/gpt-oss-120b"}

SSE_CHUNKS = [
    b"event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
    b"event: content_block_delta\ndata: {\"delta\":{\"text\":\"he\"}}\n\n",
    b"event: content_block_delta\ndata: {\"delta\":{\"text\":\"llo\"}}\n\n",
    b"event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
]

# A one-property tool, the shape the Skill tool has in Claude Code's requests: this is the
# schema _repair_tool_inputs wraps a bare-string input against (Skill "hwpx" -> {"skill": ...}).
SKILL_TOOL = {
    "name": "Skill",
    "description": "Run a named skill",
    "input_schema": {
        "type": "object",
        "properties": {"skill": {"type": "string"}},
        "required": ["skill"],
    },
}


def msg(model, text="hi"):
    return {"model": model, "max_tokens": 8, "messages": [{"role": "user", "content": text}]}


class FakeUpstreams:
    """A MockTransport handler that fakes both upstreams and records every request sent to them."""

    def __init__(self):
        self.requests = []
        self.local_models = [GEMMA]
        self.spark_models = [QWEN]
        self.spark_mode = "ok"  # ok | down | 502 | 503 | 504 | 400 | 500 | pooltimeout
        self.spark2_models = [QWEN_INSTRUCT]  # the second Spark URL's own catalog
        self.spark2_mode = "ok"  # ok | down
        self.local_mode = "ok"  # ok | pooltimeout
        self.spark_sse = None
        self.spark_sse_raise = None  # an exception the spark SSE body raises after its chunks
        self.spark_extra_headers = {}  # extra headers on the spark answer
        self.spark_error_body = None   # mode "400": override the 400 body (e.g. one carrying the key)
        self.switch_status = {
            "state": "ready", "current": QWEN["id"], "target": None, "default": QWEN["id"],
            "phase": "serving", "reason": None, "started_at": 1.0, "finished_at": 2.0,
            "last_error": None, "idle_minutes": 30, "idle_return_at": None, "cooldown_until": None,
            "profiles": [
                {"name": "qwen3-coder", "model": "/models/qwen3-coder", "kind": "text",
                 "verified": True, "description": "Qwen3 Coder 480B"},
                {"name": "gpt-oss-120b", "model": "/models/gpt-oss-120b", "kind": "text",
                 "verified": True, "description": "GPT-OSS 120B"},
                {"name": "qwen3-vl-30b", "model": "/models/qwen3-vl-30b", "kind": "vision",
                 "verified": False, "description": "Qwen3 VL 30B"},
            ],
        }
        self.switch_mode = "ok"  # ok | down | badjson
        self.switch_reply = (202, {"state": "switching", "target": "gpt-oss-120b"})

    def handler(self, request):
        self.requests.append(request)
        if request.url.host == LOCAL_HOST and request.url.port == LOCAL_PORT:
            return self._local(request)
        if request.url.host == SPARK_HOST and request.url.port == SPARK_PORT:
            return self._spark(request)
        if request.url.host == SPARK2_HOST and request.url.port == SPARK2_PORT:
            return self._spark2(request)
        if request.url.host == SWITCH_HOST and request.url.port == SWITCH_PORT:
            return self._switch(request)
        raise AssertionError(f"request sent to unexpected upstream {request.url}")

    def _local(self, request):
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": self.local_models})  # probe reads it with .json()
        if self.local_mode == "pooltimeout":
            # A custom transport bypasses httpx's pool, so saturation is simulated by raising
            # exactly what a full pool raises: the handler only runs when a slot was granted.
            raise httpx.PoolTimeout("pool timeout", request=request)
        return self._json_stream(200, {"type": "message", "content": [{"type": "text", "text": "local"}]})

    def _spark(self, request):
        # "down" refuses the connection for every path: a real ECONNREFUSED is per host:port,
        # so the /v1/models health probe must fail too, not just /v1/messages.
        if self.spark_mode == "down":
            raise httpx.ConnectError("[Errno 61] connection refused", request=request)
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": self.spark_models})
        if self.spark_mode == "pooltimeout":
            # /v1/models still answers above: the probe path (own pool) is never saturated, only
            # proxied generation is. See the _local comment for why this is raised, not queued.
            raise httpx.PoolTimeout("pool timeout", request=request)
        if self.spark_mode == "502":
            return self._json_stream(502, {"error": "bad gateway"})
        if self.spark_mode == "503":
            return self._json_stream(503, {"error": "overloaded"})
        if self.spark_mode == "504":
            return self._json_stream(504, {"error": "gateway timeout"})
        if self.spark_mode == "400":
            return self._json_stream(400, self.spark_error_body or {
                "type": "error", "error": {"type": "invalid_request_error", "message": "bad"}
            })
        if self.spark_mode == "500":
            return self._json_stream(500, {"error": "boom"})
        # The slot being torn down mid-request: the connection was made and the body sent, but it
        # dropped before any response header came back (seen live 2026-11-24 as 502 ReadError).
        if self.spark_mode == "readerror":
            raise httpx.ReadError("connection reset by peer", request=request)
        if self.spark_mode == "protoerror":
            raise httpx.RemoteProtocolError("server disconnected without sending a response", request=request)
        if self.spark_mode == "writeerror":
            raise httpx.WriteError("broken pipe", request=request)
        if self.spark_mode == "readtimeout":
            raise httpx.ReadTimeout("read timed out", request=request)
        if self.spark_sse is not None:
            return httpx.Response(
                200, content=self._aiter(self.spark_sse, self.spark_sse_raise),
                headers={"content-type": "text/event-stream", **self.spark_extra_headers},
            )
        return self._json_stream(200, {"type": "message", "content": [{"type": "text", "text": "spark"}]})

    def _spark2(self, request):
        # The second Spark URL: its own catalog, and "down" refuses every path just like _spark.
        if self.spark2_mode == "down":
            raise httpx.ConnectError("[Errno 61] connection refused", request=request)
        if request.url.path == "/v1/models":
            return httpx.Response(200, json={"data": self.spark2_models})
        return self._json_stream(200, {"type": "message", "content": [{"type": "text", "text": "spark2"}]})

    @staticmethod
    async def _aiter(chunks, raise_after=None):
        # The router reads upstreams with an async httpx client (stream=True); a real transport
        # hands it an async, not-yet-consumed body stream, so the fake must too. Eager bodies
        # (Response(json=...), sync iter(...)) are pre-consumed or sync-only and break aiter_raw().
        # raise_after: an exception raised once every chunk is out - the upstream dying mid-body.
        for chunk in chunks:
            yield chunk
        if raise_after is not None:
            raise raise_after

    def _switch(self, request):
        # The controller is polled non-streaming, so eager Response(json=...) bodies are fine here.
        if self.switch_mode == "down":
            raise httpx.ConnectError("[Errno 61] connection refused", request=request)
        if self.switch_mode == "badjson":
            return httpx.Response(200, text="{not json")
        if request.url.path == "/status":
            return httpx.Response(200, json=self.switch_status)
        if request.url.path == "/switch":
            status, body = self.switch_reply
            return httpx.Response(status, json=body)
        raise AssertionError(f"unexpected switch controller path {request.url.path}")

    def _json_stream(self, status, payload, headers=None):
        body = json.dumps(payload).encode("utf-8")
        # Response(json=...) would add this itself, but its body would be pre-consumed.
        merged = {"content-type": "application/json", **(headers or {})}
        return httpx.Response(status, content=self._aiter([body]), headers=merged)

    def sent(self, host):
        return [r for r in self.requests if r.url.host == host]

    def sent_path(self, host, path):
        return [r for r in self.requests if r.url.host == host and r.url.path == path]


class RouterTest(unittest.IsolatedAsyncioTestCase):
    SWITCH_ON = dict(
        spark_switch_url=f"http://{SWITCH_HOST}:{SWITCH_PORT}", spark_switch_token=SWITCH_TOKEN
    )

    def make(self, **overrides):
        values = dict(
            host="127.0.0.1", port=1240,
            local_url=f"http://{LOCAL_HOST}:{LOCAL_PORT}", local_model=GEMMA["id"], local_token="lmstudio",
            spark_url=f"http://{SPARK_HOST}:{SPARK_PORT}", spark_api_key=KEY, spark_prefer=["qwen3-coder"],
            spark_switch_url="", spark_switch_token="",
            health_interval=10, health_fail=2, health_ok=2, connect_timeout=2, health_timeout=5,
            max_body_mb=32,
        )
        values.update(overrides)
        self.cfg = router.Config(**values)
        self.fake = FakeUpstreams()
        self.app = router.create_app(
            self.cfg, transport=httpx.MockTransport(self.fake.handler), start_health_loop=False
        )

    async def drain_switch_refresh(self):
        """Wait for the fire-and-forget /status refresh a successful switch schedules."""
        for _ in range(500):
            if not self.app.state.health._switch_tasks:
                return
            await asyncio.sleep(0.001)
        self.fail("the switch refresh task did not finish")

    @asynccontextmanager
    async def serve(self, *, spark_up=True, spark_models=None, **overrides):
        """A running app (lifespan entered, health forced to a known state) plus a client."""
        self.make(**overrides)
        async with self.app.router.lifespan_context(self.app):
            health = self.app.state.health
            health.set_state("local", True, [dict(GEMMA)])
            if self.cfg.spark_url:
                health.set_state("spark", spark_up, [dict(m) for m in (spark_models or [QWEN])])
            self.fake.requests.clear()  # drop the startup probe's requests
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=self.app), base_url="http://127.0.0.1:1240"
            ) as client:
                yield client

    @asynccontextmanager
    async def serve_nodes(self, first, second, **overrides):
        """serve() for TWO Spark URLs (SPARK_URLS): the first fake answers the `first` catalog,
        the second the `second` one (None = that URL refuses connections). No set_state here:
        the startup probe itself decides both nodes and the aggregate folded from them."""
        self.make(
            spark_urls=[f"http://{SPARK_HOST}:{SPARK_PORT}", f"http://{SPARK2_HOST}:{SPARK2_PORT}"],
            **overrides,
        )
        self.fake.spark_models = first
        self.fake.spark2_models = second or []
        self.fake.spark2_mode = "ok" if second is not None else "down"
        async with self.app.router.lifespan_context(self.app):
            self.fake.requests.clear()  # drop the startup probe's requests
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=self.app), base_url="http://127.0.0.1:1240"
            ) as client:
                yield client

    # 1. spark-large with spark up
    async def test_spark_large_goes_to_spark(self):
        async with self.serve() as client:
            r = await client.post(
                "/v1/messages?beta=true",
                json=msg("spark-large"),
                headers={"x-api-key": "client-key-9", "anthropic-version": "2023-06-01",
                         "anthropic-beta": "context-1m-2025-08-07"},
            )
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            self.assertEqual(len(self.fake.sent(SPARK_HOST)), 1)
            req = self.fake.sent(SPARK_HOST)[0]
            self.assertEqual(req.url.path, "/v1/messages")
            self.assertEqual(req.url.params.get("beta"), "true")  # query preserved exactly
            self.assertEqual(json.loads(req.content)["model"], "qwen3-coder")
            self.assertEqual(req.headers["x-api-key"], KEY)
            self.assertEqual(req.headers["authorization"], f"Bearer {KEY}")
            self.assertEqual(req.headers["anthropic-version"], "2023-06-01")  # passes through
            self.assertEqual(req.headers["anthropic-beta"], "context-1m-2025-08-07")
            self.assertNotIn("client-key-9", str(req.headers.raw))  # client's own key not forwarded
            self.assertEqual(json.loads(r.content)["content"][0]["text"], "spark")

    # 2. preferred entry absent from the catalog -> first served model
    async def test_preferred_absent_uses_first_served(self):
        async with self.serve(spark_models=[GPT_OSS]) as client:
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            req = self.fake.sent(SPARK_HOST)[0]
            self.assertEqual(json.loads(req.content)["model"], "gpt-oss-120b")

    # 3. dynamic catalog: a model swap on the Spark is picked up by the next probe
    async def test_catalog_swap_picked_up(self):
        async with self.serve() as client:
            await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(json.loads(self.fake.sent(SPARK_HOST)[-1].content)["model"], "qwen3-coder")

            self.fake.spark_models = [GPT_OSS]
            await self.app.state.health.check_once()
            self.fake.requests.clear()

            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(json.loads(self.fake.sent(SPARK_HOST)[-1].content)["model"], "gpt-oss-120b")

            listed = (await client.get("/v1/models")).json()["data"]
            ids = [d["id"] for d in listed]
            self.assertIn("gpt-oss-120b", ids)
            self.assertNotIn("qwen3-coder", ids)
            large = next(d for d in listed if d["id"] == "spark-large")
            self.assertEqual(large["target"], "gpt-oss-120b")

    # 4. spark down -> local with LOCAL_MODEL
    async def test_spark_down_falls_back_to_local(self):
        async with self.serve(spark_up=False, spark_models=[]) as client:
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "local (spark-down)")
            self.assertEqual(len(self.fake.sent(SPARK_HOST)), 0)
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 1)
            self.assertEqual(json.loads(self.fake.sent(LOCAL_HOST)[0].content)["model"], self.cfg.local_model)
            self.assertEqual(json.loads(r.content)["content"][0]["text"], "local")

    # 4d. two Spark URLs, both up: the aggregate lists both catalogs and each request goes to
    # the URL whose /v1/models lists the model
    async def test_two_spark_urls_route_by_model(self):
        async with self.serve_nodes(
            [QWEN_INSTRUCT], [QWEN], spark_prefer=["qwen3-instruct", "qwen3-coder"]
        ) as client:
            health = self.app.state.health
            self.assertTrue(health.spark.up)
            self.assertEqual(health.spark.ids, ["qwen3-instruct", "qwen3-coder"])  # node order
            self.assertEqual(health.spark_target(), "qwen3-instruct")  # first preferred id

            r = await client.post("/v1/messages", json=msg("qwen3-coder"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            to_second = self.fake.sent(SPARK2_HOST)
            self.assertEqual(len(to_second), 1)  # served by the second URL, not the first
            self.assertEqual(json.loads(to_second[0].content)["model"], "qwen3-coder")

            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            to_first = self.fake.sent_path(SPARK_HOST, "/v1/messages")
            self.assertEqual(len(to_first), 1)
            self.assertEqual(json.loads(to_first[0].content)["model"], "qwen3-instruct")
            self.assertEqual(len(self.fake.sent(SPARK2_HOST)), 1)  # no extra hop to the dead catalog

    # 4e. the second URL down: the aggregate stays up on the first node's catalog alone, and a
    # model only the dead node served is no longer a spark model (the profile error path, no crash)
    async def test_two_spark_urls_one_down(self):
        async with self.serve_nodes([QWEN_INSTRUCT], None, **self.SWITCH_ON) as client:
            health = self.app.state.health
            self.assertTrue(health.spark.up)
            self.assertEqual(health.spark.ids, ["qwen3-instruct"])
            self.assertEqual([n.up for n in health.spark_nodes], [True, False])
            self.assertIn("ConnectError", health.spark_nodes[1].last_error)

            r = await client.post("/v1/messages", json=msg("qwen3-coder"))
            self.assertEqual(r.status_code, 400)
            self.assertIn("spark-model use qwen3-coder", r.json()["error"]["message"])
            self.assertEqual(len(self.fake.sent_path(LOCAL_HOST, "/v1/messages")), 0)

    # 4f. exclusive mode: ONE big model on the first URL, the second down -> spark-large is it
    async def test_two_spark_urls_exclusive_single(self):
        async with self.serve_nodes([GPT_OSS], None) as client:
            health = self.app.state.health
            self.assertTrue(health.spark.up)
            self.assertEqual(health.spark.ids, ["gpt-oss-120b"])
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            to_first = self.fake.sent_path(SPARK_HOST, "/v1/messages")
            self.assertEqual(len(to_first), 1)
            self.assertEqual(json.loads(to_first[0].content)["model"], "gpt-oss-120b")
            self.assertEqual(len(self.fake.sent(SPARK2_HOST)), 0)

    # 4g. /health lists one entry per spark node (urls only, no key anywhere)
    async def test_health_lists_spark_nodes(self):
        async with self.serve_nodes([QWEN_INSTRUCT], [QWEN]) as client:
            body = (await client.get("/health")).json()
            self.assertTrue(body["spark"]["up"])
            self.assertEqual([m["id"] for m in body["spark"]["models"]],
                             ["qwen3-instruct", "qwen3-coder"])
            self.assertEqual(body["spark"]["nodes"], [
                {"url": f"http://{SPARK_HOST}:{SPARK_PORT}", "up": True,
                 "models": ["qwen3-instruct"], "last_error": None},
                {"url": f"http://{SPARK2_HOST}:{SPARK2_PORT}", "up": True,
                 "models": ["qwen3-coder"], "last_error": None},
            ])

    # 4h. switching target "pair" loads every resident: a request for a not-yet-served resident
    # gets the 503 loading answer; one already served still routes normally
    async def test_pair_switch_loading_answer(self):
        async with self.serve_nodes([QWEN_INSTRUCT], None, **self.SWITCH_ON) as client:
            self.fake.switch_status = {**self.fake.switch_status, "state": "switching",
                                       "target": "pair", "phase": "loading weights",
                                       "residents": ["qwen3-instruct", "qwen3-coder"]}
            await self.app.state.health.check_once()
            r = await client.post("/v1/messages", json=msg("qwen3-coder"))
            self.assertEqual(r.status_code, 503)
            self.assertEqual(r.json()["error"]["type"], "overloaded_error")
            self.assertEqual(r.json()["error"]["message"],
                             "Spark is loading qwen3-coder (phase loading weights); "
                             "retry in a few minutes")
            self.assertEqual(r.headers.get("retry-after"), "60")

            r = await client.post("/v1/messages", json=msg("qwen3-instruct"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")

    # 4b. Claude Code 2.1.x sends mid-conversation role:"system" messages; vLLM's Anthropic
    # endpoint 400s on them, so the Spark request gets them folded into the neighbouring user
    # message as <system-reminder> text, top-level "system" untouched
    async def test_spark_folds_system_messages(self):
        async with self.serve() as client:
            body = msg("spark-large")
            body["system"] = [{"type": "text", "text": "top-level system"}]
            body["messages"].append({"role": "system", "content": [
                {"type": "text", "text": "SessionStart hook additional context: hello",
                 "cache_control": {"type": "ephemeral"}}]})
            r = await client.post("/v1/messages", json=body)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            sent = json.loads(self.fake.sent_path(SPARK_HOST, "/v1/messages")[0].content)
            self.assertEqual([m["role"] for m in sent["messages"]], ["user"])
            self.assertEqual(
                [b["text"] for b in sent["messages"][0]["content"]],
                ["hi", "<system-reminder>\nSessionStart hook additional context: hello\n</system-reminder>"],
            )
            self.assertEqual(sent["system"], body["system"])  # top-level system kept as-is

    # 4c. the local path takes the payload unchanged: after a spark failure the retry still
    # carries the role:"system" message, because LM Studio accepts it
    async def test_local_retry_keeps_system_message(self):
        async with self.serve() as client:
            self.fake.spark_mode = "down"
            body = msg("spark-large")
            body["messages"].append({"role": "system", "content": "SessionStart hook additional context"})
            r = await client.post("/v1/messages", json=body)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "local (retry)")
            sent = json.loads(self.fake.sent_path(LOCAL_HOST, "/v1/messages")[0].content)
            self.assertEqual([m["role"] for m in sent["messages"]], ["user", "system"])
            self.assertEqual(sent["messages"][1]["content"], "SessionStart hook additional context")

    # 4i. the Spark request gets assistant tool_use blocks whose input is not an object repaired
    # (seen live 2026-11-26: the Skill tool called with input "hwpx"; Claude Code kept the block
    # and vLLM 400ed the NEXT request, killing the conversation). One INFO line names the block
    # count and tool names only - never the input values, which can hold user data.
    async def test_spark_repairs_non_object_tool_inputs(self):
        async with self.serve() as client:
            body = msg("spark-large")
            body["tools"] = [SKILL_TOOL]
            body["messages"].append({"role": "assistant", "content": [
                {"type": "tool_use", "id": "chatcmpl-tool-1", "name": "Skill", "input": "hwpx"}]})
            with self.assertLogs("llm-router", level="INFO") as cm:
                r = await client.post("/v1/messages", json=body)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            sent = json.loads(self.fake.sent_path(SPARK_HOST, "/v1/messages")[0].content)
            self.assertEqual(sent["messages"][1]["content"][0]["input"], {"skill": "hwpx"})
            self.assertEqual(sent["tools"], [SKILL_TOOL])  # the tool list rides along untouched
            repairs = [rec.getMessage() for rec in cm.records if "tool_use" in rec.getMessage()]
            self.assertEqual(len(repairs), 1)  # one line for the whole request
            self.assertIn("Skill", repairs[0])
            self.assertNotIn("hwpx", repairs[0])  # never the input value

    # 4j. the repair composes with the system-message fold in one Spark request: the system
    # message folds into the preceding user message AND the malformed tool input is wrapped
    async def test_spark_repair_composes_with_system_fold(self):
        async with self.serve() as client:
            body = msg("spark-large")
            body["tools"] = [SKILL_TOOL]
            body["messages"].append({"role": "system", "content": "SessionStart hook context"})
            body["messages"].append({"role": "assistant", "content": [
                {"type": "tool_use", "id": "chatcmpl-tool-1", "name": "Skill", "input": "hwpx"}]})
            r = await client.post("/v1/messages", json=body)
            self.assertEqual(r.status_code, 200)
            sent = json.loads(self.fake.sent_path(SPARK_HOST, "/v1/messages")[0].content)
            self.assertEqual([m["role"] for m in sent["messages"]], ["user", "assistant"])
            self.assertEqual(
                [b["text"] for b in sent["messages"][0]["content"]],
                ["hi", "<system-reminder>\nSessionStart hook context\n</system-reminder>"],
            )
            self.assertEqual(sent["messages"][1]["content"][0]["input"], {"skill": "hwpx"})

    # 4k. the local path is NOT repaired: LM Studio's handling of non-object tool_use inputs is
    # unverified and it has accepted everything seen so far, so its requests stay unchanged
    async def test_local_payload_is_not_repaired(self):
        async with self.serve() as client:
            self.fake.spark_mode = "down"
            body = msg("spark-large")
            body["tools"] = [SKILL_TOOL]
            body["messages"].append({"role": "assistant", "content": [
                {"type": "tool_use", "id": "chatcmpl-tool-1", "name": "Skill", "input": "hwpx"}]})
            r = await client.post("/v1/messages", json=body)
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "local (retry)")
            sent = json.loads(self.fake.sent_path(LOCAL_HOST, "/v1/messages")[0].content)
            self.assertEqual(sent["messages"][1]["content"][0]["input"], "hwpx")  # untouched

    # 5. connect error and 503 retry once on local; 400 and 500 pass through
    async def test_spark_failure_handling(self):
        async with self.serve() as client:
            self.fake.spark_mode = "down"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "local (retry)")
            self.assertEqual(len(self.fake.sent(SPARK_HOST)), 1)  # tried spark once
            self.assertEqual(json.loads(self.fake.sent(LOCAL_HOST)[-1].content)["model"], self.cfg.local_model)

            self.fake.spark_mode = "503"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "local (retry)")

            self.fake.spark_mode = "400"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.headers.get("x-route"), "spark")
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 2)  # no retry was added
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")

            self.fake.spark_mode = "500"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 500)
            self.assertEqual(r.headers.get("x-route"), "spark")
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 2)

    # 5b. a gateway timeout may mean the request is already running on the Spark;
    # failing over to local would run the same prompt twice
    async def test_gateway_timeout_is_not_retried(self):
        async with self.serve() as client:
            self.fake.spark_mode = "504"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 504)  # passed through, unchanged
            self.assertEqual(r.headers.get("x-route"), "spark")
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 0)  # no second run

            # 502/503 still fail over to local
            for mode in ("502", "503"):
                self.fake.spark_mode = mode
                r = await client.post("/v1/messages", json=msg("spark-large"))
                self.assertEqual(r.status_code, 200)
                self.assertEqual(r.headers.get("x-route"), "local (retry)")

    # 5c. the connection drops before any response header (a slot being torn down during a
    # switch): nothing reached the client yet, so it is retried on local like a refused connect.
    # Seen live 2026-11-24: this came back as 502 "spark request failed: ReadError".
    async def test_pre_header_disconnect_retries_on_local(self):
        async with self.serve() as client:
            for mode in ("readerror", "protoerror", "writeerror"):
                with self.subTest(mode=mode):
                    self.fake.spark_mode = mode
                    self.fake.requests.clear()
                    r = await client.post("/v1/messages", json=msg("spark-large"))
                    self.assertEqual(r.status_code, 200)
                    self.assertEqual(r.headers.get("x-route"), "local (retry)")
                    self.assertEqual(len(self.fake.sent_path(SPARK_HOST, "/v1/messages")), 1)
                    local = self.fake.sent_path(LOCAL_HOST, "/v1/messages")
                    self.assertEqual(len(local), 1)
                    self.assertEqual(json.loads(local[0].content)["model"], self.cfg.local_model)

    # 5d. a read timeout is NOT retried (same reason as 504: the Spark may still be running it).
    # Proxied reads are unbounded in production, so this only guards the classification.
    async def test_read_timeout_is_not_retried(self):
        async with self.serve() as client:
            self.fake.spark_mode = "readtimeout"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 502)
            self.assertEqual(r.json()["error"]["type"], "api_error")
            self.assertEqual(len(self.fake.sent_path(LOCAL_HOST, "/v1/messages")), 0)

    # 5e. a pre-header drop is a per-request event, not a health verdict: spark stays up
    async def test_pre_header_disconnect_leaves_health_alone(self):
        async with self.serve() as client:
            self.fake.spark_mode = "readerror"
            await client.post("/v1/messages", json=msg("spark-large"))
            self.assertTrue(self.app.state.health.spark.up)

    # 6. local-fast with the local token
    async def test_local_fast_uses_local_token(self):
        async with self.serve() as client:
            r = await client.post("/v1/messages", json=msg("local-fast"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "local")
            req = self.fake.sent(LOCAL_HOST)[0]
            self.assertEqual(req.headers["x-api-key"], "lmstudio")
            self.assertEqual(req.headers["authorization"], "Bearer lmstudio")
            self.assertEqual(json.loads(req.content)["model"], self.cfg.local_model)

    # 7. unknown model / bad body
    async def test_unknown_model_and_bad_body(self):
        async with self.serve() as client:
            r = await client.post("/v1/messages", json=msg("no-such-model"))
            self.assertEqual(r.status_code, 400)
            err = r.json()
            self.assertEqual(err["type"], "error")
            self.assertEqual(err["error"]["type"], "invalid_request_error")
            self.assertIn("no-such-model", err["error"]["message"])

            r = await client.post(
                "/v1/messages", content=b"not json", headers={"content-type": "application/json"}
            )
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")

            r = await client.post("/v1/messages", json={"max_tokens": 8, "messages": []})
            self.assertEqual(r.status_code, 400)

    # 8. DNS-rebind protection
    async def test_bad_host_rejected(self):
        async with self.serve() as client:
            r = await client.post("/v1/messages", json=msg("local-fast"), headers={"host": "evil.example:1240"})
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")
            # and the router itself is fine on its own address
            r = await client.get("/health")
            self.assertEqual(r.status_code, 200)

    # 8b. browser defenses: cross-origin POST and non-JSON POST bodies
    async def test_cross_origin_post_rejected(self):
        """A malicious page can POST without any CORS preflight; browsers
        always send Origin on such a POST, so a non-loopback Origin is 403."""
        async with self.serve() as client:
            r = await client.post("/v1/messages", json=msg("local-fast"),
                                  headers={"origin": "https://evil.example"})
            self.assertEqual(r.status_code, 403)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 0)  # nothing forwarded

            r = await client.post("/v1/messages", json=msg("local-fast"),
                                  headers={"origin": "null"})
            self.assertEqual(r.status_code, 403)

        async with self.serve(**self.SWITCH_ON) as client:
            r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"},
                                  headers={"origin": "https://evil.example"})
            self.assertEqual(r.status_code, 403)
            self.assertEqual(len(self.fake.sent_path(SWITCH_HOST, "/switch")), 0)

    async def test_loopback_origin_and_charset_are_fine(self):
        """A loopback Origin and a charset parameter must not break real
        clients (a browser extension served from 127.0.0.1, an SDK)."""
        async with self.serve() as client:
            r = await client.post(
                "/v1/messages", json=msg("local-fast"),
                headers={"origin": "http://127.0.0.1:1240",
                         "content-type": "application/json; charset=utf-8"},
            )
            self.assertEqual(r.status_code, 200)

    async def test_text_plain_post_rejected_before_any_handler(self):
        """text/plain is what a web page can send cross-origin without a
        preflight; it is rejected with 415 and the switch controller is never
        reached."""
        async with self.serve(**self.SWITCH_ON) as client:
            r = await client.post(
                "/v1/spark/switch",
                content=json.dumps({"profile": "gpt-oss-120b"}).encode(),
                headers={"content-type": "text/plain"},
            )
            self.assertEqual(r.status_code, 415)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")
            self.assertEqual(len(self.fake.sent(SWITCH_HOST)), 0)  # transport never called

            r = await client.post("/v1/messages",
                                  content=json.dumps(msg("local-fast")).encode(),
                                  headers={"content-type": "text/plain"})
            self.assertEqual(r.status_code, 415)
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 0)

    async def test_gets_need_no_content_type_or_origin(self):
        async with self.serve(**self.SWITCH_ON) as client:
            self.assertEqual((await client.get("/health")).status_code, 200)
            self.assertEqual((await client.get("/v1/models")).status_code, 200)
            self.assertEqual((await client.get("/v1/spark/status")).status_code, 200)

    # 9. streaming SSE passes through intact
    async def test_sse_stream_passthrough(self):
        async with self.serve() as client:
            self.fake.spark_sse = SSE_CHUNKS
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("content-type"), "text/event-stream")
            self.assertEqual(r.headers.get("x-route"), "spark")
            self.assertEqual(r.content, b"".join(SSE_CHUNKS))

    # 9b. a compressed upstream answer keeps its Content-Encoding: the body is
    # forwarded raw, so stripping the header would hand the client bytes it
    # cannot decode
    async def test_compressed_upstream_response_passthrough(self):
        async with self.serve() as client:
            plain = b"the quick brown spark answers in gzip"
            self.fake.spark_sse = [gzip.compress(plain)]
            self.fake.spark_extra_headers = {"content-encoding": "gzip"}
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("content-encoding"), "gzip")
            # httpx decompressed it transparently, which proves both that the
            # gzip bytes arrived intact and that the header arrived to decode them
            self.assertEqual(r.content, plain)

    # 9c-9h: an Anthropic SSE stream that ends before message_stop (the Spark slot torn down
    # mid-generation - seen live 2026-11-24: 201 deltas, then the socket closed with neither
    # message_stop nor an error event) gets ONE closing `event: error` so the client can tell
    # a cut answer from a finished one. The bytes already forwarded are never altered.
    @staticmethod
    def sse_events(body: bytes) -> list[tuple[str, dict]]:
        """(event name, parsed data) for every complete event in an SSE body."""
        events = []
        for block in body.replace(b"\r\n", b"\n").split(b"\n\n"):
            name, data = None, None
            for line in block.split(b"\n"):
                if line.startswith(b"event:"):
                    name = line[6:].strip().decode()
                elif line.startswith(b"data:"):
                    data = line[5:].strip()
            if name is not None and data is not None:
                events.append((name, json.loads(data)))
        return events

    async def test_sse_cut_by_upstream_error_gets_error_event(self):
        async with self.serve() as client:
            partial = SSE_CHUNKS[:3]  # message_start + two deltas, no message_stop
            self.fake.spark_sse = partial
            self.fake.spark_sse_raise = httpx.RemoteProtocolError(
                "peer closed connection without sending complete message body"
            )
            with self.assertLogs("llm-router", level="WARNING") as cm:
                r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertTrue(r.content.startswith(b"".join(partial)))  # forwarded bytes untouched
            events = self.sse_events(r.content)
            self.assertEqual(events[-1][0], "error")
            self.assertEqual(events[-1][1]["type"], "error")
            self.assertEqual(events[-1][1]["error"]["type"], "api_error")
            self.assertEqual([e for e, _ in events].count("error"), 1)
            self.assertTrue(any("message_stop" in line for line in cm.output))

    async def test_sse_clean_close_without_message_stop_gets_error_event(self):
        async with self.serve() as client:
            self.fake.spark_sse = SSE_CHUNKS[:3]  # upstream ends the body cleanly, just early
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertTrue(r.content.startswith(b"".join(SSE_CHUNKS[:3])))
            self.assertEqual(self.sse_events(r.content)[-1][0], "error")

    async def test_sse_cut_mid_event_still_parses_closing_error(self):
        # The cut lands inside an event: the closing error must still start on its own event
        # boundary, so a client sees it as a separate, parseable event.
        async with self.serve() as client:
            self.fake.spark_sse = [SSE_CHUNKS[0], b"event: content_block_delta\ndata: {\"del"]
            self.fake.spark_sse_raise = httpx.ReadError("connection reset by peer")
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertTrue(r.content.startswith(SSE_CHUNKS[0] + b"event: content_block_delta\ndata: {\"del"))
            tail = r.content.rsplit(b"\n\n", 2)[-2]  # last complete event
            self.assertIn(b"event: error", tail)
            self.assertEqual(self.sse_events(tail + b"\n\n")[-1][1]["error"]["type"], "api_error")

    async def test_sse_message_stop_split_across_chunks_is_complete(self):
        async with self.serve() as client:
            whole = b"".join(SSE_CHUNKS)
            cut = whole.index(b"message_stop") + 7  # "message" | "_stop"
            self.fake.spark_sse = [whole[:cut], whole[cut:]]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, whole)  # nothing appended

    async def test_sse_upstream_error_event_is_not_doubled(self):
        async with self.serve() as client:
            upstream_error = (
                b"event: error\ndata: {\"type\":\"error\",\"error\":"
                b"{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n"
            )
            self.fake.spark_sse = [SSE_CHUNKS[0], upstream_error]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, SSE_CHUNKS[0] + upstream_error)  # passed through as-is

    async def test_sse_cut_on_other_paths_is_left_alone(self):
        # Only the Anthropic /v1/messages stream has a message_stop contract; an OpenAI-shaped
        # /v1/chat/completions stream (data: [DONE]) and count_tokens are passed through as-is.
        async with self.serve() as client:
            self.fake.spark_sse = [b"data: {\"choices\":[]}\n\n"]
            r = await client.post("/v1/chat/completions", json=msg("spark-large"))
            self.assertEqual(r.content, b"data: {\"choices\":[]}\n\n")

    async def test_sse_cut_with_content_encoding_is_left_alone(self):
        # A compressed body cannot take plaintext appended to it; it is forwarded raw as before.
        async with self.serve() as client:
            plain = SSE_CHUNKS[0]
            self.fake.spark_sse = [gzip.compress(plain)]
            self.fake.spark_extra_headers = {"content-encoding": "gzip"}
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, plain)

    async def test_non_sse_body_is_left_alone(self):
        async with self.serve() as client:
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.json()["content"][0]["text"], "spark")

    async def test_sse_text_mentioning_message_stop_is_still_closed_out(self):
        # Generated text may contain the word "message_stop"; only a real event line ends a stream.
        async with self.serve() as client:
            mention = b"event: content_block_delta\ndata: {\"delta\":{\"text\":\"message_stop\"}}\n\n"
            self.fake.spark_sse = [SSE_CHUNKS[0], mention]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertTrue(r.content.startswith(SSE_CHUNKS[0] + mention))
            self.assertEqual(self.sse_events(r.content)[-1][0], "error")

    async def test_sse_error_event_without_space_is_not_doubled(self):
        # The space after "event:" is optional in SSE; "event:error" is the same error event.
        async with self.serve() as client:
            upstream_error = (
                b"event:error\ndata:{\"type\":\"error\",\"error\":"
                b"{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n"
            )
            self.fake.spark_sse = [SSE_CHUNKS[0], upstream_error]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, SSE_CHUNKS[0] + upstream_error)

    async def test_sse_error_event_as_first_bytes_is_not_doubled(self):
        async with self.serve() as client:
            upstream_error = (
                b"event: error\ndata: {\"type\":\"error\",\"error\":"
                b"{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n"
            )
            self.fake.spark_sse = [upstream_error]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, upstream_error)

    async def test_transport_error_on_unguarded_path_still_propagates(self):
        # Outside the guarded stream a mid-body transport error must still abort the response
        # (as before), not turn into a clean end the client would take for a finished answer.
        async with self.serve() as client:
            self.fake.spark_sse = [b"data: {\"choices\":[]}\n\n"]
            self.fake.spark_sse_raise = httpx.ReadError("connection reset by peer")
            with self.assertRaises(httpx.ReadError):
                await client.post("/v1/chat/completions", json=msg("spark-large"))

    async def test_sse_event_name_starting_with_error_is_still_closed_out(self):
        # Only an event named exactly "error" ends a stream; "error_notice" is some other event.
        async with self.serve() as client:
            other = b"event: error_notice\ndata: {\"type\":\"error_notice\"}\n\n"
            self.fake.spark_sse = [SSE_CHUNKS[0], other]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertTrue(r.content.startswith(SSE_CHUNKS[0] + other))
            names = [e for e, _ in self.sse_events(r.content)]
            self.assertEqual(names[-1], "error")
            self.assertEqual(names.count("error"), 1)

    async def test_sse_crlf_message_stop_is_complete(self):
        async with self.serve() as client:
            whole = b"".join(SSE_CHUNKS).replace(b"\n", b"\r\n")
            self.fake.spark_sse = [whole]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, whole)  # nothing appended

    async def test_sse_message_stop_split_before_line_end_is_complete(self):
        # The line end that closes the marker may arrive in the next chunk.
        async with self.serve() as client:
            whole = b"".join(SSE_CHUNKS)
            cut = whole.index(b"event: message_stop") + len(b"event: message_stop")
            self.fake.spark_sse = [whole[:cut], whole[cut:]]
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, whole)

    async def test_sse_lookalike_content_type_is_left_alone(self):
        # text/event-stream-custom is a different media type, not SSE.
        async with self.serve() as client:
            self.fake.spark_sse = SSE_CHUNKS[:3]
            self.fake.spark_extra_headers = {"content-type": "text/event-stream-custom"}
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.content, b"".join(SSE_CHUNKS[:3]))

    async def test_sse_content_type_with_params_is_still_guarded(self):
        async with self.serve() as client:
            self.fake.spark_sse = SSE_CHUNKS[:3]
            self.fake.spark_extra_headers = {"content-type": "Text/Event-Stream; charset=utf-8"}
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(self.sse_events(r.content)[-1][0], "error")

    # 10. thresholds: 2 to drop, 2 to raise, first probe decides
    async def test_health_thresholds(self):
        async with self.serve() as client:
            health = self.app.state.health
            self.assertTrue(health.spark.up)

            self.fake.spark_mode = "down"
            await health.check_once()
            self.assertTrue(health.spark.up)  # one failure is not enough
            self.assertEqual(health.spark.fails, 1)
            await health.check_once()
            self.assertFalse(health.spark.up)  # two failures drop it

            self.fake.spark_mode = "ok"
            await health.check_once()
            self.assertFalse(health.spark.up)  # one success is not enough
            self.assertEqual(health.spark.oks, 1)
            await health.check_once()
            self.assertTrue(health.spark.up)  # two successes raise it

            self.fake.spark_models = [GPT_OSS]
            await health.check_once()
            self.assertEqual(health.spark_target(), "gpt-oss-120b")

    async def test_first_probe_decides_from_unknown(self):
        self.make()
        self.fake.spark_mode = "down"
        async with self.app.router.lifespan_context(self.app):  # runs one startup check_once()
            health = self.app.state.health
            self.assertFalse(health.spark.up)  # decided by the single first probe
            self.assertTrue(health.spark.seen)
            self.assertEqual(health.spark.fails, 1)
            self.assertTrue(health.local.up)  # local's first probe decided too
            self.assertIn("ConnectError", health.spark.last_error)

    # 11. no secrets in /health, /v1/models or the logs
    async def test_no_secrets_in_bodies_or_logs(self):
        async with self.serve() as client:
            with self.assertLogs("llm-router", level="INFO") as cm:
                await client.post("/v1/messages", json=msg("spark-large", "top-secret-llama"))
                health_body = (await client.get("/health")).text
                models_body = (await client.get("/v1/models")).text
            logs = "\n".join(cm.output)
            self.assertIn("/v1/messages", logs)  # the request line is there
            self.assertNotIn(KEY, logs)
            self.assertNotIn("top-secret-llama", logs)
            self.assertNotIn("x-api-key", logs)
            for body in (health_body, models_body):
                self.assertNotIn(KEY, body)

    # 13. count_tokens is routed like /v1/messages
    async def test_count_tokens_routed_the_same(self):
        async with self.serve() as client:
            r = await client.post("/v1/messages/count_tokens", json={"model": "spark-large", "messages": []})
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            req = self.fake.sent(SPARK_HOST)[0]
            self.assertEqual(req.url.path, "/v1/messages/count_tokens")
            self.assertEqual(json.loads(req.content)["model"], "qwen3-coder")
            self.assertEqual(req.headers["x-api-key"], KEY)

    # 14. body over MAX_BODY_MB
    async def test_body_too_large(self):
        async with self.serve(max_body_mb=1) as client:
            big = msg("local-fast")
            big["pad"] = "x" * (1024 * 1024 + 128)
            r = await client.post("/v1/messages", json=big)
            self.assertEqual(r.status_code, 413)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")
            self.assertEqual(len(self.fake.sent(LOCAL_HOST)), 0)

    # 15. repeated request headers survive the filtering (both values reach the upstream)
    async def test_duplicate_headers_survive_filtering(self):
        async with self.serve() as client:
            r = await client.post(
                "/v1/messages", json=msg("spark-large"),
                headers=[
                    ("anthropic-beta", "context-1m-2025-08-07"),
                    ("anthropic-beta", "prompt-caching-2024-07-31"),
                ],
            )
            self.assertEqual(r.status_code, 200)
            req = self.fake.sent(SPARK_HOST)[0]
            self.assertEqual(
                req.headers.get_list("anthropic-beta"),
                ["context-1m-2025-08-07", "prompt-caching-2024-07-31"],
            )

    # 16. GET /v1/spark/status serves the cached controller status; feature off -> 404
    async def test_spark_status_endpoint(self):
        async with self.serve() as client:  # SPARK_SWITCH_URL unset
            r = await client.get("/v1/spark/status")
            self.assertEqual(r.status_code, 404)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")
            self.assertIn("not configured", r.json()["error"]["message"])
            r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})
            self.assertEqual(r.status_code, 404)
            self.assertIn("not configured", r.json()["error"]["message"])

        async with self.serve(**self.SWITCH_ON) as client:
            r = await client.get("/v1/spark/status")
            self.assertEqual(r.status_code, 200)
            body = r.json()
            self.assertTrue(body["switch_ok"])
            self.assertEqual(body["switch"]["state"], "ready")
            self.assertEqual(body["switch"]["current"], "qwen3-coder")
            self.assertEqual(
                [p["name"] for p in body["switch"]["profiles"]],
                ["qwen3-coder", "gpt-oss-120b", "qwen3-vl-30b"],
            )
            self.assertTrue(body["spark"]["up"])
            self.assertEqual(body["spark"]["models"][0]["id"], "qwen3-coder")

    # 17. POST /v1/spark/switch: passthrough (202/409/429), auth header, body, 502, bad bodies
    async def test_spark_switch_passthrough(self):
        async with self.serve(**self.SWITCH_ON) as client:
            self.fake.switch_reply = (202, {"state": "switching", "target": "gpt-oss-120b"})
            r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})
            self.assertEqual(r.status_code, 202)
            self.assertEqual(r.json(), {"state": "switching", "target": "gpt-oss-120b"})
            sent_switch = [q for q in self.fake.sent(SWITCH_HOST) if q.url.path == "/switch"]
            self.assertEqual(len(sent_switch), 1)
            self.assertEqual(sent_switch[0].headers["authorization"], f"Bearer {SWITCH_TOKEN}")
            self.assertEqual(json.loads(sent_switch[0].content), {"profile": "gpt-oss-120b"})
            await self.drain_switch_refresh()
            # the accepted switch triggered one immediate /status refresh, not waited for
            self.assertEqual(len([q for q in self.fake.sent(SWITCH_HOST) if q.url.path == "/status"]), 1)

            self.fake.switch_reply = (409, {"error": {"type": "conflict",
                                                      "message": "already switching to gpt-oss-120b"},
                                            "target": "gpt-oss-120b"})
            r = await client.post("/v1/spark/switch", json={"profile": "qwen3-vl-30b"})
            self.assertEqual(r.status_code, 409)  # controller's code and body, unchanged
            self.assertEqual(r.json()["error"]["message"], "already switching to gpt-oss-120b")

            self.fake.switch_reply = (429, {"error": {"type": "rate_limit_error",
                                                      "message": "cooldown active"},
                                            "retry_after": 120})
            r = await client.post("/v1/spark/switch", json={"profile": "qwen3-vl-30b"})
            self.assertEqual(r.status_code, 429)
            self.assertEqual(r.json()["retry_after"], 120)
            # 409/429 schedule no refresh
            self.assertEqual(len([q for q in self.fake.sent(SWITCH_HOST) if q.url.path == "/status"]), 1)

            self.fake.switch_mode = "down"
            r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})
            self.assertEqual(r.status_code, 502)
            self.assertEqual(r.json()["error"]["type"], "api_error")

            # invalid request bodies never leave the router
            r = await client.post("/v1/spark/switch", content=b"not json",
                                  headers={"content-type": "application/json"})
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.json()["error"]["type"], "invalid_request_error")
            r = await client.post("/v1/spark/switch", json={"profile": ""})
            self.assertEqual(r.status_code, 400)
            r = await client.post("/v1/spark/switch", json={"nope": 1})
            self.assertEqual(r.status_code, 400)
            # every controller request this test caused, in order: the 202 (recorded even when the
            # connection fails), its refresh, the 409, the 429 and the refused one behind the 502.
            self.assertEqual(
                [q.url.path for q in self.fake.sent(SWITCH_HOST)],
                ["/switch", "/status", "/switch", "/switch", "/switch"],
            )

    # 18. a known-but-not-loaded profile: 400 with the spark-model hint; loading -> 503 + Retry-After
    async def test_unloaded_profile_errors(self):
        async with self.serve(**self.SWITCH_ON) as client:
            r = await client.post("/v1/messages", json=msg("gpt-oss-120b"))
            self.assertEqual(r.status_code, 400)
            err = r.json()["error"]
            self.assertEqual(err["type"], "invalid_request_error")
            self.assertIn("gpt-oss-120b is a Spark profile but is not loaded", err["message"])
            self.assertIn("current: qwen3-coder", err["message"])
            self.assertIn("spark-model use gpt-oss-120b", err["message"])
            self.assertEqual(len(self.fake.sent_path(SPARK_HOST, "/v1/messages")), 0)  # no request
            self.assertEqual(len(self.fake.sent_path(LOCAL_HOST, "/v1/messages")), 0)  # no fallback

            self.fake.switch_status = {**self.fake.switch_status, "state": "switching",
                                       "target": "gpt-oss-120b", "phase": "loading weights"}
            await self.app.state.health.check_once()
            r = await client.post("/v1/messages", json=msg("gpt-oss-120b"))
            self.assertEqual(r.status_code, 503)
            err = r.json()["error"]
            self.assertEqual(err["type"], "overloaded_error")
            self.assertEqual(err["message"],
                             "Spark is loading gpt-oss-120b (phase loading weights); "
                             "retry in a few minutes")
            self.assertEqual(r.headers.get("retry-after"), "60")
            self.assertEqual(len(self.fake.sent_path(LOCAL_HOST, "/v1/messages")), 0)

            # a profile while current is null reads "(current: none)"; a served id resolves normally
            self.fake.switch_status = {**self.fake.switch_status, "state": "ready", "target": None,
                                       "current": None, "phase": "loading done"}
            await self.app.state.health.check_once()
            r = await client.post("/v1/messages", json=msg("qwen3-vl-30b"))
            self.assertEqual(r.status_code, 400)
            self.assertIn("current: none", r.json()["error"]["message"])

            r = await client.post("/v1/messages", json=msg("qwen3-coder"))
            self.assertEqual(r.status_code, 200)  # in the spark catalog: routed, no special casing
            self.assertEqual(r.headers.get("x-route"), "spark")

        # feature off: the same name is just an unknown model again
        async with self.serve() as client:
            r = await client.post("/v1/messages", json=msg("gpt-oss-120b"))
            self.assertEqual(r.status_code, 400)
            self.assertIn("unknown model", r.json()["error"]["message"])

    # 19. /v1/models also lists the not-loaded profiles
    async def test_models_list_profiles(self):
        async with self.serve(**self.SWITCH_ON) as client:
            data = (await client.get("/v1/models")).json()["data"]
            by_id: dict[str, list[dict]] = {}
            for entry in data:
                by_id.setdefault(entry["id"], []).append(entry)
            self.assertEqual(by_id["gpt-oss-120b"][0]["route"], "spark (not loaded)")
            self.assertEqual(by_id["gpt-oss-120b"][0]["kind"], "text")
            self.assertEqual(by_id["qwen3-vl-30b"][0]["route"], "spark (not loaded)")
            self.assertEqual(by_id["qwen3-vl-30b"][0]["kind"], "vision")
            self.assertEqual(len(by_id["qwen3-coder"]), 1)  # served: listed once, as spark
            self.assertEqual(by_id["qwen3-coder"][0]["route"], "spark")

        async with self.serve() as client:  # feature off: no profile entries at all
            data = (await client.get("/v1/models")).json()["data"]
            self.assertNotIn("gpt-oss-120b", [d["id"] for d in data])
            self.assertNotIn("qwen3-vl-30b", [d["id"] for d in data])

    # 20. a controller /status failure never touches local/spark state, it only marks the cache stale
    async def test_switch_failure_isolated(self):
        async with self.serve(**self.SWITCH_ON) as client:
            health = self.app.state.health
            self.assertTrue(health.switch.ok)

            self.fake.switch_mode = "down"
            await health.check_once()
            self.assertTrue(health.local.up)      # untouched
            self.assertTrue(health.spark.up)      # untouched
            self.assertEqual(health.spark.fails, 0)
            self.assertEqual(health.local.fails, 0)
            self.assertFalse(health.switch.ok)    # only the cache went stale
            self.assertIn("ConnectError", health.switch.last_error)
            self.assertEqual(health.switch.status["state"], "ready")  # previous status kept

            body = (await client.get("/health")).json()
            self.assertEqual(body["switch"], {"configured": True, "ok": False,
                                              "state": "ready", "current": "qwen3-coder"})
            body = (await client.get("/v1/spark/status")).json()
            self.assertFalse(body["switch_ok"])
            self.assertEqual(body["switch"]["state"], "ready")
            self.assertTrue(body["spark"]["up"])

            self.fake.switch_mode = "badjson"
            await health.check_once()
            self.assertIn("invalid JSON", health.switch.last_error)
            self.assertTrue(health.spark.up)

            self.fake.switch_mode = "ok"
            await health.check_once()
            self.assertTrue(health.switch.ok)     # and it recovers by itself

    # 21. the switch token never appears in a body or a log line
    async def test_switch_token_nowhere(self):
        async with self.serve(**self.SWITCH_ON) as client:
            with self.assertLogs("llm-router", level="INFO") as cm:
                self.fake.switch_reply = (202, {"state": "switching", "target": "gpt-oss-120b"})
                r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})
                self.assertEqual(r.status_code, 202)
                await self.drain_switch_refresh()
                await client.post("/v1/messages", json=msg("gpt-oss-120b"))  # the logged 400 path
                self.fake.switch_mode = "down"
                await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})  # logged 502
                await self.app.state.health.check_once()                        # logged stale line
                health_body = (await client.get("/health")).text
                models_body = (await client.get("/v1/models")).text
                status_body = (await client.get("/v1/spark/status")).text
            self.assertNotIn(SWITCH_TOKEN, "\n".join(cm.output))
            for body in (r.text, health_body, models_body, status_body):
                self.assertNotIn(SWITCH_TOKEN, body)

    # 23. empty SPARK_API_KEY: the probe sends no auth headers at all and the Spark still comes up
    async def test_health_probe_without_key_sends_no_auth(self):
        """A keyless vLLM answers /v1/models without any auth. The router must not
        build 'authorization: Bearer ' / empty 'x-api-key' headers for it: httpx
        rejects those values as illegal, so the probe would never even leave."""
        self.make(spark_api_key="")
        async with self.app.router.lifespan_context(self.app):  # runs one startup check_once()
            health = self.app.state.health
            self.assertTrue(health.spark.up)  # first successful probe decided: up
            probe = self.fake.sent_path(SPARK_HOST, "/v1/models")[0]
            self.assertNotIn("authorization", probe.headers)
            self.assertNotIn("x-api-key", probe.headers)

    # 23b. with a key both headers are sent, with the exact stripped values (regression guard)
    async def test_health_probe_with_key_sends_exact_headers(self):
        self.make(spark_api_key="  test-key  ")  # padded: proves the value is stripped
        async with self.app.router.lifespan_context(self.app):
            self.assertTrue(self.app.state.health.spark.up)
            probe = self.fake.sent_path(SPARK_HOST, "/v1/models")[0]
            self.assertEqual(probe.headers["x-api-key"], "test-key")
            self.assertEqual(probe.headers["authorization"], "Bearer test-key")

    # 24. forwarding with no SPARK_API_KEY: the client's own auth is dropped and nothing replaces it
    async def test_forward_without_key_never_sends_client_auth(self):
        async with self.serve(spark_api_key="") as client:
            r = await client.post(
                "/v1/messages", json=msg("spark-large"),
                headers={"authorization": "Bearer client-secret", "x-api-key": "client-secret"},
            )
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.headers.get("x-route"), "spark")
            req = self.fake.sent_path(SPARK_HOST, "/v1/messages")[0]
            self.assertNotIn("authorization", req.headers)
            self.assertNotIn("x-api-key", req.headers)
            self.assertNotIn("client-secret", str(req.headers.raw))  # nothing leaked either way

    # 25. a whitespace-only key behaves exactly like no key
    async def test_whitespace_only_key_behaves_like_empty(self):
        self.make(spark_api_key="  ")
        async with self.app.router.lifespan_context(self.app):
            self.assertTrue(self.app.state.health.spark.up)
            probe = self.fake.sent_path(SPARK_HOST, "/v1/models")[0]
            self.assertNotIn("authorization", probe.headers)
            self.assertNotIn("x-api-key", probe.headers)

    # 26. switch probes without SPARK_SWITCH_TOKEN send no authorization header either
    async def test_switch_probe_without_token_sends_no_auth(self):
        async with self.serve(
            spark_switch_url=f"http://{SWITCH_HOST}:{SWITCH_PORT}", spark_switch_token=""
        ) as client:
            await self.app.state.health.check_once()
            status = [q for q in self.fake.sent(SWITCH_HOST) if q.url.path == "/status"][-1]
            self.assertNotIn("authorization", status.headers)
            # and the switch POST helper keeps the same rule
            r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})
            self.assertEqual(r.status_code, 202)
            await self.drain_switch_refresh()
            posted = [q for q in self.fake.sent(SWITCH_HOST) if q.url.path == "/switch"][0]
            self.assertNotIn("authorization", posted.headers)

    # 27. spark pool saturation is overload, not an outage: 503 overloaded_error, no local
    # fallback, and the health state does not move
    async def test_spark_pool_timeout_is_overload_not_outage(self):
        async with self.serve() as client:
            self.fake.spark_mode = "pooltimeout"
            r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 503)
            self.assertEqual(r.json()["error"]["type"], "overloaded_error")
            self.assertEqual(r.headers.get("retry-after"), "5")
            self.assertEqual(len(self.fake.sent_path(LOCAL_HOST, "/v1/messages")), 0)  # no fallback
            self.assertTrue(self.app.state.health.spark.up)  # overload never marks a backend down

    # 27b. local pool saturation answers the same honest 503 instead of "unreachable"
    async def test_local_pool_timeout_is_overload(self):
        async with self.serve() as client:
            self.fake.local_mode = "pooltimeout"
            r = await client.post("/v1/messages", json=msg("local-fast"))
            self.assertEqual(r.status_code, 503)
            self.assertEqual(r.json()["error"]["type"], "overloaded_error")
            self.assertEqual(r.headers.get("retry-after"), "5")

    # 27c. proxies and probes/switch ride two separate clients, so a saturated proxy pool
    # can neither time the probe out nor block model switching
    async def test_control_client_is_separate(self):
        async with self.serve() as client:
            self.assertIsNot(self.app.state.client, self.app.state.control_client)
            self.assertIs(self.app.state.health.client, self.app.state.control_client)

    # 27d. the health probe reads /v1/models through its own pool, so proxied saturation
    # never bleeds into health decisions
    async def test_probe_unaffected_by_message_pool_timeout(self):
        async with self.serve() as client:
            self.fake.spark_mode = "pooltimeout"
            await self.app.state.health.check_once()
            self.assertTrue(self.app.state.health.spark.up)
            self.assertEqual(self.app.state.health.spark.fails, 0)

    # 27e. the switch POST goes through the control client: with the proxy client replaced
    # by an object that fails on any use, switching still succeeds
    async def test_switch_post_uses_control_client(self):
        class ExplodingClient:
            def __getattr__(self, name):
                raise AssertionError("the proxy client must not be used for control calls")

        async with self.serve(**self.SWITCH_ON) as client:
            self.fake.switch_reply = (202, {"state": "switching", "target": "gpt-oss-120b"})
            self.app.state.client = ExplodingClient()
            r = await client.post("/v1/spark/switch", json={"profile": "gpt-oss-120b"})
            self.assertEqual(r.status_code, 202)
            await self.drain_switch_refresh()

    # 31. an upstream 4xx body passes through byte-for-byte AND leaves exactly one masked warning:
    # vLLM's reason ("'max_tokens' ... is too large") is readable afterwards, the key never is
    async def test_upstream_error_body_logged_masked_and_forwarded(self):
        async with self.serve() as client:
            self.fake.spark_mode = "400"
            self.fake.spark_error_body = {
                "type": "error",
                "error": {"type": "invalid_request_error",
                          "message": f"'max_tokens' of 32000 is too large (key {KEY})"},
            }
            with self.assertLogs("llm-router", level="INFO") as cm:
                r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 400)
            self.assertEqual(r.headers.get("x-route"), "spark")
            # the exact bytes the upstream sent: the capture must not change what the client gets
            self.assertEqual(r.content, json.dumps(self.fake.spark_error_body).encode())
            warnings = [line for line in cm.output if "upstream error" in line]
            self.assertEqual(len(warnings), 1)  # exactly one line
            self.assertIn("route=spark", warnings[0])
            self.assertIn("status=400", warnings[0])
            self.assertIn("'max_tokens' of 32000 is too large", warnings[0])  # the cause is readable
            self.assertNotIn(KEY, warnings[0])                                 # the key never is

    # 31b. a 2xx answer streams as before: no capture happened, no "upstream error" line appears
    async def test_upstream_success_logs_no_upstream_error(self):
        async with self.serve() as client:
            with self.assertLogs("llm-router", level="INFO") as cm:
                r = await client.post("/v1/messages", json=msg("spark-large"))
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.content, json.dumps(
                {"type": "message", "content": [{"type": "text", "text": "spark"}]}
            ).encode())
            self.assertNotIn("upstream error", "\n".join(cm.output))


class FoldSystemMessagesTest(unittest.TestCase):
    """_fold_system_messages: the pure rewrite that keeps vLLM's Anthropic endpoint from
    rejecting Claude Code's mid-conversation role:"system" messages with a 400."""

    def test_identity_without_system_messages(self):
        payload = {"model": "m", "messages": [{"role": "user", "content": "hi"},
                                              {"role": "assistant", "content": "ho"}]}
        self.assertIs(router._fold_system_messages(payload), payload)
        no_messages = {"model": "m", "system": "top-level"}
        self.assertIs(router._fold_system_messages(no_messages), no_messages)

    def test_appended_to_preceding_user_with_list_content(self):
        payload = {"model": "m", "messages": [
            {"role": "user", "content": [{"type": "text", "text": "hi"}]},
            {"role": "system", "content": [
                {"type": "text", "text": "SessionStart hook additional context",
                 "cache_control": {"type": "ephemeral"}}]},
        ]}
        before = json.loads(json.dumps(payload))
        folded = router._fold_system_messages(payload)
        self.assertIsNot(folded, payload)
        self.assertIsNot(folded["messages"], payload["messages"])
        self.assertEqual([m["role"] for m in folded["messages"]], ["user"])
        wrapped = folded["messages"][0]["content"][1]
        self.assertEqual(wrapped["type"], "text")
        self.assertEqual(wrapped["text"],
                         "<system-reminder>\nSessionStart hook additional context\n</system-reminder>")
        self.assertEqual(wrapped["cache_control"], {"type": "ephemeral"})  # kept on the copy
        self.assertEqual(payload, before)  # the input was not mutated

    def test_str_content_on_both_sides(self):
        payload = {"model": "m", "messages": [
            {"role": "user", "content": "hi"},
            {"role": "system", "content": "extra context"},
        ]}
        folded = router._fold_system_messages(payload)
        self.assertEqual(folded["messages"], [
            {"role": "user", "content": [
                {"type": "text", "text": "hi"},
                {"type": "text", "text": "<system-reminder>\nextra context\n</system-reminder>"},
            ]},
        ])

    def test_prepended_to_following_user(self):
        payload = {"model": "m", "messages": [
            {"role": "system", "content": "first!"},
            {"role": "user", "content": "hi"},
        ]}
        folded = router._fold_system_messages(payload)
        self.assertEqual(folded["messages"], [
            {"role": "user", "content": [
                {"type": "text", "text": "<system-reminder>\nfirst!\n</system-reminder>"},
                {"type": "text", "text": "hi"},
            ]},
        ])

    def test_new_user_message_between_assistants(self):
        payload = {"model": "m", "messages": [
            {"role": "assistant", "content": "a1"},
            {"role": "system", "content": "mid"},
            {"role": "assistant", "content": "a2"},
        ]}
        folded = router._fold_system_messages(payload)
        self.assertEqual([m["role"] for m in folded["messages"]], ["assistant", "user", "assistant"])
        self.assertEqual(folded["messages"][1]["content"],
                         [{"type": "text", "text": "<system-reminder>\nmid\n</system-reminder>"}])

    def test_consecutive_system_messages_share_a_target_in_order(self):
        payload = {"model": "m", "messages": [
            {"role": "user", "content": "hi"},
            {"role": "system", "content": "one"},
            {"role": "system", "content": [{"type": "text", "text": "two"}]},
            {"role": "assistant", "content": "ok"},
        ]}
        folded = router._fold_system_messages(payload)
        self.assertEqual([m["role"] for m in folded["messages"]], ["user", "assistant"])
        self.assertEqual([b["text"] for b in folded["messages"][0]["content"]],
                         ["hi", "<system-reminder>\none\n</system-reminder>",
                          "<system-reminder>\ntwo\n</system-reminder>"])

    def test_top_level_system_untouched(self):
        payload = {"model": "m", "system": [{"type": "text", "text": "real system"}],
                   "messages": [{"role": "user", "content": "hi"},
                                {"role": "system", "content": "fold me"}]}
        folded = router._fold_system_messages(payload)
        self.assertIs(folded["system"], payload["system"])
        self.assertEqual(folded["model"], "m")
        self.assertEqual([m["role"] for m in folded["messages"]], ["user"])


class RepairToolInputsTest(unittest.TestCase):
    """_repair_tool_inputs: the pure rewrite that keeps vLLM's Anthropic endpoint from rejecting
    assistant tool_use blocks whose input is not an object. Seen live 2026-11-26: the Skill tool
    called with input "hwpx", Claude Code kept the block in the history, and vLLM 400ed the NEXT
    request ('input should be a valid dictionary'), killing the conversation."""

    @staticmethod
    def toolcall(value, name="Skill", tools=None):
        """A minimal payload whose assistant message carries one tool_use block with `value`."""
        return {
            "model": "m",
            "tools": tools if tools is not None else [SKILL_TOOL],
            "messages": [
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": [
                    {"type": "text", "text": "calling the tool"},
                    {"type": "tool_use", "id": "chatcmpl-tool-1", "name": name, "input": value},
                ]},
            ],
        }

    def test_string_parsing_to_an_object_is_used_as_is(self):
        repaired = router._repair_tool_inputs(self.toolcall('{"skill": "hwpx", "verbose": true}'))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"],
                         {"skill": "hwpx", "verbose": True})

    def test_single_property_schema_wraps_the_string(self):
        repaired = router._repair_tool_inputs(self.toolcall("hwpx"))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"skill": "hwpx"})

    def test_json_scalar_and_list_strings_wrap_the_parsed_value(self):
        repaired = router._repair_tool_inputs(self.toolcall("42"))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"skill": 42})
        repaired = router._repair_tool_inputs(self.toolcall('[1, "two"]'))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"skill": [1, "two"]})

    def test_single_required_property_among_several(self):
        bash = {"name": "Bash", "input_schema": {
            "type": "object",
            "properties": {"command": {"type": "string"}, "timeout": {"type": "number"}},
            "required": ["command"]}}
        repaired = router._repair_tool_inputs(self.toolcall("ls -la", name="Bash", tools=[bash]))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"command": "ls -la"})

    def test_no_single_property_wraps_under_input(self):
        fetch = {"name": "WebFetch", "input_schema": {
            "type": "object",
            "properties": {"url": {"type": "string"}, "prompt": {"type": "string"}},
            "required": ["url", "prompt"]}}
        repaired = router._repair_tool_inputs(
            self.toolcall("example.com", name="WebFetch", tools=[fetch]))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"input": "example.com"})
        # an unknown tool name, or no tools list at all, falls back the same way
        repaired = router._repair_tool_inputs(self.toolcall("hwpx", name="NoSuchTool"))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"input": "hwpx"})
        payload = self.toolcall("hwpx")
        del payload["tools"]
        repaired = router._repair_tool_inputs(payload)
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"input": "hwpx"})

    def test_missing_and_null_input_become_the_empty_object(self):
        repaired = router._repair_tool_inputs(self.toolcall(None))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {})
        payload = {"model": "m", "tools": [SKILL_TOOL], "messages": [
            {"role": "assistant", "content": [
                {"type": "tool_use", "id": "chatcmpl-tool-2", "name": "Skill"},  # no input key
            ]},
        ]}
        repaired = router._repair_tool_inputs(payload)
        self.assertEqual(repaired["messages"][0]["content"][0]["input"], {})

    def test_non_string_non_object_values_wrap_themselves(self):
        repaired = router._repair_tool_inputs(self.toolcall([1, 2]))
        self.assertEqual(repaired["messages"][1]["content"][1]["input"], {"skill": [1, 2]})

    def test_dict_inputs_and_clean_payloads_return_the_same_object(self):
        payload = self.toolcall({"skill": "hwpx"})
        self.assertIs(router._repair_tool_inputs(payload), payload)
        bare = {"model": "m"}
        self.assertIs(router._repair_tool_inputs(bare), bare)  # no messages at all
        # tool_use-looking blocks in a USER message, or non-tool_use blocks, are never touched
        hijack = {"model": "m", "tools": [SKILL_TOOL], "messages": [
            {"role": "user", "content": [
                {"type": "tool_use", "id": "t1", "name": "Skill", "input": "hwpx"}]},
            {"role": "assistant", "content": [{"type": "text", "text": "no input here"}]},
        ]}
        self.assertIs(router._repair_tool_inputs(hijack), hijack)
        with self.assertNoLogs("llm-router", level="INFO"):
            router._repair_tool_inputs(hijack)

    def test_the_input_payload_is_not_mutated(self):
        payload = self.toolcall("hwpx")
        before = json.loads(json.dumps(payload))
        repaired = router._repair_tool_inputs(payload)
        self.assertEqual(payload, before)
        self.assertIsNot(repaired, payload)
        self.assertIsNot(repaired["messages"], payload["messages"])
        self.assertIsNot(repaired["messages"][1], payload["messages"][1])
        self.assertIsNot(repaired["messages"][1]["content"], payload["messages"][1]["content"])
        self.assertIsNot(repaired["messages"][1]["content"][1], payload["messages"][1]["content"][1])
        # untouched neighbours are shared, not copied
        self.assertIs(repaired["messages"][0], payload["messages"][0])
        self.assertIs(repaired["messages"][1]["content"][0], payload["messages"][1]["content"][0])
        # and the original block still carries its malformed input
        self.assertEqual(payload["messages"][1]["content"][1]["input"], "hwpx")

    def test_multiple_blocks_repaired_with_one_log_line(self):
        payload = {"model": "m", "tools": [SKILL_TOOL], "messages": [
            {"role": "assistant", "content": [
                {"type": "tool_use", "id": "t1", "name": "Skill", "input": "hwpx"},
                {"type": "tool_use", "id": "t2", "name": "Skill", "input": {"skill": "fine"}},
                {"type": "tool_use", "id": "t3", "name": "Grep", "input": "pattern"},
            ]},
        ]}
        with self.assertLogs("llm-router", level="INFO") as cm:
            repaired = router._repair_tool_inputs(payload)
        self.assertEqual([b["input"] for b in repaired["messages"][0]["content"]],
                         [{"skill": "hwpx"}, {"skill": "fine"}, {"input": "pattern"}])
        self.assertEqual(payload["messages"][0]["content"][0]["input"], "hwpx")  # input intact
        lines = [rec.getMessage() for rec in cm.records if "tool_use" in rec.getMessage()]
        self.assertEqual(len(lines), 1)
        self.assertIn("2", lines[0])               # the repaired-block count
        self.assertIn("Skill", lines[0])
        self.assertIn("Grep", lines[0])
        self.assertNotIn("hwpx", lines[0])         # never the input values
        self.assertNotIn("pattern", lines[0])


class ErrorExcerptTest(unittest.TestCase):
    """_error_excerpt: the pure masker that makes an upstream error body safe for one log line."""

    def test_masks_secret_bearer_and_sk_key(self):
        raw = (f"spark key {KEY} here, Authorization: Bearer ab12cd34ef56gh78, "
               f"plus sk-z9y8x7w6v5u4t4 in the message").encode()
        out = router._error_excerpt(raw, None, [KEY, ""])  # empty secrets are skipped
        self.assertNotIn(KEY, out)
        self.assertNotIn("ab12cd34ef56gh78", out)
        self.assertNotIn("z9y8x7w6v5u4t4", out)
        self.assertIn("***", out)
        self.assertIn("Bearer ***", out)
        self.assertIn("sk-***", out)

    def test_collapses_newlines_and_control_chars(self):
        out = router._error_excerpt(b'{"error":\r\n\t "message": "a\x00b"}', None, [])
        self.assertEqual(out, '{"error": "message": "a b"}')

    def test_truncates_to_300_with_ellipsis(self):
        out = router._error_excerpt(("x" * 500).encode(), None, [])
        self.assertEqual(out, "x" * 300 + "…")
        # exactly 300 is left alone: the ellipsis only marks an actual cut
        self.assertEqual(router._error_excerpt(b"x" * 300, None, []), "x" * 300)

    def test_encoded_body_is_named_not_decoded(self):
        # a compressed error body cannot be decoded here (the router forwards it raw), so the
        # excerpt names the codec instead of logging gzip garbage
        self.assertEqual(router._error_excerpt(gzip.compress(b"nope"), "gzip", []), "<encoded:gzip>")
        self.assertEqual(router._error_excerpt(b"plain", "identity", []), "plain")
        self.assertEqual(router._error_excerpt(b"plain", None, []), "plain")


class OriginHostTest(unittest.TestCase):
    # 8c. the Origin parser: only http(s) with a loopback host is acceptable
    def test_variants(self):
        f = router._origin_host
        self.assertEqual(f("http://127.0.0.1:1240"), "127.0.0.1")
        self.assertEqual(f("https://localhost:9999"), "localhost")
        self.assertEqual(f("http://[::1]:1240"), "::1")
        self.assertEqual(f("HTTP://LocalHost:1240"), "localhost")
        self.assertEqual(f("https://user:pw@localhost:1240/a?b#c"), "localhost")
        self.assertEqual(f("https://evil.example"), "evil.example")
        self.assertIsNone(f("null"))
        self.assertIsNone(f("chrome-extension://abcdef"))
        self.assertIsNone(f(""))
        self.assertIsNone(f("http://"))
        self.assertIsNone(f("not a url"))


class LoadConfigTest(unittest.TestCase):
    # 12. env-file parsing, permissions, precedence, host validation
    def test_load_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "# a comment\n"
                    "\n"
                    "export LLM_ROUTER_PORT='1300'\n"
                    'LLM_ROUTER_HOST="localhost"\n'
                    "LOCAL_MODEL=gemma-4-e4b-it-mlx\n"
                    "SPARK_PREFER=qwen3-coder, gpt-oss-120b\n"
                    "this line has no equals sign\n"
                )
            os.chmod(path, 0o600)

            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.port, 1300)
            self.assertEqual(cfg.host, "localhost")
            self.assertEqual(cfg.local_model, "gemma-4-e4b-it-mlx")
            self.assertEqual(cfg.spark_prefer, ["qwen3-coder", "gpt-oss-120b"])
            self.assertEqual(cfg.spark_url, "")  # unset = Spark disabled
            self.assertEqual(cfg.spark_api_key, "")

            cfg = router.load_config(env_file=path, environ={"LLM_ROUTER_PORT": "1400"})
            self.assertEqual(cfg.port, 1400)  # the process environment wins
            self.assertEqual(cfg.local_model, "gemma-4-e4b-it-mlx")  # the file still fills the rest

            os.chmod(path, 0o644)
            with self.assertRaises(router.ConfigError):  # group/other readable
                router.load_config(env_file=path, environ={})
            os.chmod(path, 0o600)

            with self.assertRaises(router.ConfigError):  # non-loopback bind
                router.load_config(env_file=path, environ={"LLM_ROUTER_HOST": "0.0.0.0"})

            cfg = router.load_config(env_file=os.path.join(tmp, "absent"), environ={})
            self.assertEqual(cfg.port, 1240)  # a missing file just means defaults

    def test_bad_numbers(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("LLM_ROUTER_PORT=abc\n")
            os.chmod(path, 0o600)
            with self.assertRaises(router.ConfigError):
                router.load_config(env_file=path, environ={})

    # 22. SPARK_SWITCH_URL / SPARK_SWITCH_TOKEN: same file/process rules, empty = feature off
    def test_switch_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("SPARK_SWITCH_URL=http://172.30.1.35:8010/\nSPARK_SWITCH_TOKEN=tok-file\n")
            os.chmod(path, 0o600)

            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.spark_switch_url, "http://172.30.1.35:8010")  # trailing / dropped
            self.assertEqual(cfg.spark_switch_token, "tok-file")

            cfg = router.load_config(env_file=path, environ={"SPARK_SWITCH_TOKEN": "tok-proc"})
            self.assertEqual(cfg.spark_switch_token, "tok-proc")  # process env wins

            cfg = router.load_config(env_file=os.path.join(tmp, "absent"), environ={})
            self.assertEqual(cfg.spark_switch_url, "")  # unset = feature off
            self.assertEqual(cfg.spark_switch_token, "")

    # 30. SPARK_URLS: comma list parsed (spaces, trailing /, duplicates and empties dropped);
    # unset or junk-only falls back to SPARK_URL; spark_url is always the first entry
    def test_spark_urls_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")

            def write(text):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
                os.chmod(path, 0o600)

            write("SPARK_URLS=http://a.local:8000, http://a.local:8001/, ,http://a.local:8000/\n")
            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.spark_urls, ["http://a.local:8000", "http://a.local:8001"])
            self.assertEqual(cfg.spark_url, "http://a.local:8000")  # first entry either way

            # SPARK_URLS wins over SPARK_URL
            write("SPARK_URL=http://old.local:8000\n"
                  "SPARK_URLS=http://new.local:8000/,http://new.local:8001\n")
            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.spark_urls, ["http://new.local:8000", "http://new.local:8001"])
            self.assertEqual(cfg.spark_url, "http://new.local:8000")

            # unset, or junk-only (commas/spaces), falls back to the single SPARK_URL
            write("SPARK_URL=http://single.local:8000/\n")
            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.spark_urls, ["http://single.local:8000"])

            write("SPARK_URL=http://single.local:8000\nSPARK_URLS= , ,\n")
            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.spark_urls, ["http://single.local:8000"])

            # neither set: the Spark is off
            write("SPARK_URLS=,\n")
            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.spark_urls, [])
            self.assertEqual(cfg.spark_url, "")

            # a Config built from spark_url alone still means that one URL (tests, old callers)
            cfg = router.Config(spark_url="http://direct.local:8000")
            self.assertEqual(cfg.spark_urls, ["http://direct.local:8000"])

    # 28. UPSTREAM_MAX_CONNECTIONS / UPSTREAM_POOL_TIMEOUT: parsed, defaulted, and refused
    # when zero, negative or not a number
    def test_upstream_pool_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")

            def write(text):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
                os.chmod(path, 0o600)

            write("UPSTREAM_MAX_CONNECTIONS=512\nUPSTREAM_POOL_TIMEOUT=2.5\n")
            cfg = router.load_config(env_file=path, environ={})
            self.assertEqual(cfg.upstream_max_connections, 512)
            self.assertEqual(cfg.upstream_pool_timeout, 2.5)

            cfg = router.load_config(env_file=os.path.join(tmp, "absent"), environ={})
            self.assertEqual(cfg.upstream_max_connections, 256)  # unset = defaults
            self.assertEqual(cfg.upstream_pool_timeout, 10.0)

            for name in ("UPSTREAM_MAX_CONNECTIONS", "UPSTREAM_POOL_TIMEOUT"):
                for bad in ("0", "-1", "abc"):
                    write(f"{name}={bad}\n")
                    with self.assertRaises(router.ConfigError):
                        router.load_config(env_file=path, environ={})

    # 29. UPSTREAM_IPV4_ONLY: default 1; 1/0, true/false, yes/no, on/off in any case; else refused
    def test_upstream_ipv4_only_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")

            def write(text):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
                os.chmod(path, 0o600)

            cfg = router.load_config(env_file=os.path.join(tmp, "absent"), environ={})
            self.assertTrue(cfg.upstream_ipv4_only)  # unset = IPv4-only by default

            for raw in ("1", "true", "TRUE", "Yes", "on"):
                write(f"UPSTREAM_IPV4_ONLY={raw}\n")
                cfg = router.load_config(env_file=path, environ={})
                self.assertTrue(cfg.upstream_ipv4_only, raw)

            for raw in ("0", "false", "False", "no", "OFF"):
                write(f"UPSTREAM_IPV4_ONLY={raw}\n")
                cfg = router.load_config(env_file=path, environ={})
                self.assertFalse(cfg.upstream_ipv4_only, raw)

            write("UPSTREAM_IPV4_ONLY=maybe\n")
            with self.assertRaises(router.ConfigError):
                router.load_config(env_file=path, environ={})

    # 32. ACCESS_LOG: default off; 1/true/yes on, 0/false/no off, anything else refused
    def test_access_log_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "env")

            def write(text):
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(text)
                os.chmod(path, 0o600)

            cfg = router.load_config(env_file=os.path.join(tmp, "absent"), environ={})
            self.assertFalse(cfg.access_log)  # unset = off: the router logs proxied requests itself

            for raw in ("1", "true", "TRUE", "Yes"):
                write(f"ACCESS_LOG={raw}\n")
                cfg = router.load_config(env_file=path, environ={})
                self.assertTrue(cfg.access_log, raw)

            for raw in ("0", "false", "False", "no", "OFF"):
                write(f"ACCESS_LOG={raw}\n")
                cfg = router.load_config(env_file=path, environ={})
                self.assertFalse(cfg.access_log, raw)

            write("ACCESS_LOG=bogus\n")
            with self.assertRaises(router.ConfigError):
                router.load_config(env_file=path, environ={})


class UpstreamTransportTest(unittest.TestCase):
    """_upstream_transport: production upstreams connect IPv4-only, and the pool limits live on
    the transport — a client handed a transport ignores its own limits=, so they must arrive
    here or the pools would silently shrink to httpx defaults."""

    # a. ipv4 on: the pool binds local 0.0.0.0, which makes anyio resolve IPv4-only, and the
    # given Limits end up as the pool's own sizes
    def test_ipv4_on_binds_zero_and_keeps_limits(self):
        limits = httpx.Limits(max_connections=256, max_keepalive_connections=64)
        transport = router._upstream_transport(router.Config(), limits)
        self.assertEqual(transport._pool._local_address, "0.0.0.0")
        self.assertEqual(transport._pool._max_connections, 256)
        self.assertEqual(transport._pool._max_keepalive_connections, 64)

    # b. ipv4 off: no local address restriction, both families allowed again
    def test_ipv4_off_leaves_local_address_unset(self):
        transport = router._upstream_transport(
            router.Config(upstream_ipv4_only=False), httpx.Limits()
        )
        self.assertIsNone(transport._pool._local_address)


class UpstreamTransportSocketTest(unittest.IsolatedAsyncioTestCase):
    """The IPv4-only transport over a REAL socket (no MockTransport): a tiny HTTP server bound
    to 127.0.0.1 only must be reachable through http://localhost:<port>/ — localhost resolves
    ::1 first on macOS, so the request only succeeds when resolution is restricted to IPv4."""

    async def test_ipv4_transport_reaches_ipv4_server_via_localhost(self):
        async def handle(reader, writer):
            try:
                while await reader.readline() not in (b"\r\n", b""):  # request head
                    pass
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        server = await asyncio.start_server(handle, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        try:
            transport = router._upstream_transport(router.Config(), httpx.Limits())
            async with httpx.AsyncClient(transport=transport, trust_env=False) as client:
                r = await client.get(f"http://localhost:{port}/")
            self.assertEqual(r.status_code, 200)
            self.assertEqual(r.content, b"ok")
        finally:
            server.close()
            await server.wait_closed()


class FdLimitTest(unittest.TestCase):
    """The startup FD-limit raise: each proxied stream costs two descriptors, so the soft
    RLIMIT_NOFILE must be raised above macOS's default 256. getrlimit/setrlimit are patched
    (on router.resource) so the real process limit is never touched by these tests."""

    # a. soft below needed, hard unlimited: raise straight to needed
    def test_raises_soft_limit_to_needed(self):
        with mock.patch("router.resource.getrlimit", return_value=(256, resource.RLIM_INFINITY)), \
                mock.patch("router.resource.setrlimit") as setrlimit:
            self.assertEqual(router._raise_fd_limit(4096, router.log), 4096)
        setrlimit.assert_called_once_with(resource.RLIMIT_NOFILE, (4096, resource.RLIM_INFINITY))

    # b. soft already enough: no setrlimit call at all
    def test_no_change_when_soft_already_enough(self):
        with mock.patch("router.resource.getrlimit", return_value=(8192, 8192)), \
                mock.patch("router.resource.setrlimit") as setrlimit:
            self.assertEqual(router._raise_fd_limit(4096, router.log), 8192)
        setrlimit.assert_not_called()

    # c. hard limit below needed: raise only to the hard limit and warn about the cap
    def test_hard_limit_caps_the_raise(self):
        with mock.patch("router.resource.getrlimit", return_value=(256, 1024)), \
                mock.patch("router.resource.setrlimit") as setrlimit:
            with self.assertLogs("llm-router", level="WARNING"):
                self.assertEqual(router._raise_fd_limit(4096, router.log), 1024)
        setrlimit.assert_called_once_with(resource.RLIMIT_NOFILE, (1024, 1024))

    # d. setrlimit refuses: keep the old soft limit, log a warning, do not raise
    def test_setrlimit_failure_keeps_old_soft(self):
        with mock.patch("router.resource.getrlimit", return_value=(256, resource.RLIM_INFINITY)), \
                mock.patch("router.resource.setrlimit", side_effect=ValueError("too high")):
            with self.assertLogs("llm-router", level="WARNING"):
                self.assertEqual(router._raise_fd_limit(4096, router.log), 256)

    # e. the needed limit follows the configured proxy pool size (2 sockets per stream)
    def test_fd_needed(self):
        self.assertEqual(router._fd_needed(router.Config()), 4096)  # default pool 256 -> floor wins
        self.assertEqual(router._fd_needed(router.Config(upstream_max_connections=3000)), 6256)


class SetupLoggingTest(unittest.TestCase):
    # 33. _setup_logging: httpx/httpcore per-request INFO noise (the 10-second probes) is dropped
    # to WARNING; their real connection failures still surface
    def test_httpx_and_httpcore_at_warning(self):
        router._setup_logging()
        self.assertEqual(logging.getLogger("httpx").level, logging.WARNING)
        self.assertEqual(logging.getLogger("httpcore").level, logging.WARNING)


if __name__ == "__main__":
    unittest.main()
