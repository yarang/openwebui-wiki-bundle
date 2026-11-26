#!/usr/bin/env python3
"""llm-router - one Anthropic-compatible base URL in front of two backends.

Claude Code points at this router (default http://127.0.0.1:1240) instead of at LM Studio or the Spark
directly. Both backends already speak the Anthropic /v1/messages API, so no format translation happens:
the router rewrites the top-level `model` field, sets each backend's own auth header, streams the
response back untouched, and fails over to local when the Spark is down.

Backends:
  local  LM Studio on this Mac (small model, fast tier, always the fallback)
  spark  a DGX Spark running vLLM on the LAN, at one or several URLs (SPARK_URLS). Each URL is
         probed separately and a request goes to the one whose /v1/models lists the model. What is
         served changes over time, so ids are read from every health probe, never hardcoded.

Optionally (SPARK_SWITCH_URL), a spark-switch controller on the Spark is also polled: its cached
status names the profiles it can load, so asking for one that is not loaded gets a helpful 400
("spark-model use <name>") or a 503 while it loads. Switching itself stays explicit - only
POST /v1/spark/switch (the spark-model CLI) ever asks for a model change.

Aliases: local-fast -> LOCAL_MODEL; spark-large -> the first SPARK_PREFER entry the Spark is actually
serving, else the first model it lists. Real ids route to the backend whose catalog lists them.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import resource
import sys
import time
from contextlib import asynccontextmanager, suppress
from dataclasses import dataclass, field

import httpx
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.datastructures import Headers as StarletteHeaders
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("llm-router")

DEFAULT_ENV_FILE = "~/.config/llm-router/env"
LOOPBACK_HOSTS = ("127.0.0.1", "::1", "localhost")

ALIAS_FAST = "local-fast"
ALIAS_LARGE = "spark-large"

# Hop-by-hop headers (RFC 7230 6.1) plus everything the router replaces itself: the client's auth must
# never reach the Spark, and the client's content-length describes the body before the model rewrite.
REQUEST_DROP = frozenset({
    "host", "content-length", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "transfer-encoding", "upgrade", "accept-encoding", "x-api-key", "authorization",
    "cookie",
})
# Streaming re-chunks the body, so the upstream's content-length no longer describes what is sent.
# content-encoding is KEPT: the body is forwarded with aiter_raw() (no re-encoding), so if an
# upstream answers compressed the client needs the header to decode it.
RESPONSE_DROP = frozenset({
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
    "transfer-encoding", "upgrade", "content-length",
})
# Only failures that mean "the Spark never started the request". 504 is deliberately absent: a
# gateway timeout means generation may already be running there, and failing over to local would
# run (and bill) the same prompt twice.
RETRY_STATUSES = frozenset({502, 503})
SWITCH_BODY_LIMIT = 4096  # POST /v1/spark/switch is one profile name, not a prompt
ERROR_CAPTURE = 4096      # bytes of an upstream 4xx/5xx body set aside for the log line
ERROR_EXCERPT_CHARS = 300 # characters the masked excerpt in that log line is cut to
# SSE_END_MARKERS mean an Anthropic SSE stream already ended the proper way (see _stream). Every
# marker starts with "\n", so it can only match an event LINE - a JSON data line cannot hold a raw
# newline, so the words "message_stop" inside generated text end nothing. Each marker also ends
# with the line end that CLOSES the event name: "error_notice" is a different event than "error",
# and without the line end the shared prefix alone would wrongly end the stream. The "\n" variant
# matches an LF line end, the "\r" variant the "\r" opening a CRLF one. The longest minus one byte
# is carried across chunk boundaries, since a marker - its line end included - can be split in two.
SSE_END_MARKERS = tuple(
    marker + line_end
    for marker in (
        b"\nevent: message_stop", b"\nevent:message_stop",  # the space after "event:" is optional
        b"\nevent: error", b"\nevent:error",
    )
    for line_end in (b"\n", b"\r")
)
SSE_TAIL_KEEP = max(len(m) for m in SSE_END_MARKERS) - 1


class ConfigError(Exception):
    """Bad configuration. The message is safe to print: it never contains the Spark key."""


# --------------------------------------------------------------------------- config --------

@dataclass
class Config:
    host: str = "127.0.0.1"
    port: int = 1240
    local_url: str = "http://127.0.0.1:1234"
    local_model: str = "google/gemma-4-e4b"
    local_token: str = "lmstudio"
    spark_urls: list[str] = field(default_factory=list)  # every Spark URL, each probed separately
    spark_url: str = ""            # spark_urls[0] or ""; empty = Spark disabled, all goes to local
    spark_api_key: str = ""
    spark_switch_url: str = ""     # empty = spark-switch controller unused (the feature is off)
    spark_switch_token: str = ""
    spark_prefer: list[str] = field(default_factory=lambda: ["qwen3-coder"])
    health_interval: int = 10      # seconds between background probes
    health_fail: int = 2           # consecutive failures before up -> down
    health_ok: int = 2             # consecutive successes before down -> up
    connect_timeout: float = 2
    health_timeout: float = 5
    max_body_mb: int = 32
    upstream_max_connections: int = 256  # proxy pool size; probes/switch get their own small pool
    upstream_pool_timeout: float = 10
    upstream_ipv4_only: bool = True      # connect to upstreams over IPv4 only (see _upstream_transport)
    access_log: bool = False             # uvicorn's per-request access lines; proxied requests get a line already

    def __post_init__(self):
        # Config(spark_url=...) on its own (tests, single-URL env files) still means that one URL.
        if not self.spark_urls and self.spark_url:
            self.spark_urls = [self.spark_url]


def _parse_env_file(path: str) -> dict[str, str]:
    """KEY=VALUE lines, '#' comments, blank lines, optional quotes, optional leading 'export '.
    No shell evaluation: whatever the line says after '=' is the value, quotes stripped."""
    values: dict[str, str] = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].strip()
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            if key:
                values[key] = value
    return values


def load_config(env_file: str | None = None, environ=os.environ) -> Config:
    """Process environment wins over the env file; the file's default path is
    ~/.config/llm-router/env, overridable with LLM_ROUTER_ENV_FILE. A file that lets group/others
    read it is refused (the Spark key lives there)."""
    path = env_file or os.path.expanduser(environ.get("LLM_ROUTER_ENV_FILE") or DEFAULT_ENV_FILE)
    file_values: dict[str, str] = {}
    if os.path.exists(path):
        mode = os.stat(path).st_mode & 0o777
        if mode & 0o077:
            raise ConfigError(
                f"{path} is readable by group/others (mode {oct(mode)}); chmod 600 {path} first"
            )
        file_values = _parse_env_file(path)

    def env(name: str, default: str = "") -> str:
        for source in (environ, file_values):
            if source.get(name):
                return source[name]
        return default

    host = env("LLM_ROUTER_HOST", "127.0.0.1")
    if host not in LOOPBACK_HOSTS:
        raise ConfigError(
            f"LLM_ROUTER_HOST must be a loopback address (127.0.0.1, ::1 or localhost), not {host!r}"
        )

    def as_int(name: str, default: int) -> int:
        raw = env(name, str(default))
        try:
            return int(raw)
        except ValueError:
            raise ConfigError(f"{name} must be an integer, got {raw!r}") from None

    def as_float(name: str, default: float) -> float:
        raw = env(name, str(default))
        try:
            return float(raw)
        except ValueError:
            raise ConfigError(f"{name} must be a number, got {raw!r}") from None

    def as_bool(name: str, default: bool) -> bool:
        raw = env(name, "1" if default else "0").lower()
        if raw in ("1", "true", "yes", "on"):
            return True
        if raw in ("0", "false", "no", "off"):
            return False
        raise ConfigError(f"{name} must be a boolean (1/0, true/false, yes/no, on/off), got {raw!r}")

    prefer = [part.strip() for part in env("SPARK_PREFER", "qwen3-coder").split(",") if part.strip()]

    # SPARK_URLS is the several-URLs spelling and wins; SPARK_URL alone still means one URL.
    # Duplicates are dropped keeping order, so :8000 and :8000/ are the same node once.
    spark_urls: list[str] = []
    for part in env("SPARK_URLS").split(","):
        part = part.strip().rstrip("/")
        if part and part not in spark_urls:
            spark_urls.append(part)
    if not spark_urls:
        single = env("SPARK_URL").strip().rstrip("/")
        if single:
            spark_urls = [single]

    upstream_max_connections = as_int("UPSTREAM_MAX_CONNECTIONS", 256)
    if upstream_max_connections <= 0:
        raise ConfigError(f"UPSTREAM_MAX_CONNECTIONS must be > 0, got {upstream_max_connections}")
    upstream_pool_timeout = as_float("UPSTREAM_POOL_TIMEOUT", 10.0)
    if upstream_pool_timeout <= 0:
        raise ConfigError(f"UPSTREAM_POOL_TIMEOUT must be > 0, got {upstream_pool_timeout}")
    upstream_ipv4_only = as_bool("UPSTREAM_IPV4_ONLY", True)

    return Config(
        host=host,
        port=as_int("LLM_ROUTER_PORT", 1240),
        local_url=env("LOCAL_URL", "http://127.0.0.1:1234").rstrip("/"),
        local_model=env("LOCAL_MODEL", "google/gemma-4-e4b"),
        local_token=env("LOCAL_TOKEN", "lmstudio"),
        spark_url=spark_urls[0] if spark_urls else "",
        spark_urls=spark_urls,
        spark_api_key=env("SPARK_API_KEY"),
        spark_switch_url=env("SPARK_SWITCH_URL").rstrip("/"),
        spark_switch_token=env("SPARK_SWITCH_TOKEN"),
        spark_prefer=prefer,
        health_interval=as_int("HEALTH_INTERVAL", 10),
        health_fail=as_int("HEALTH_FAIL", 2),
        health_ok=as_int("HEALTH_OK", 2),
        connect_timeout=as_float("CONNECT_TIMEOUT", 2.0),
        health_timeout=as_float("HEALTH_TIMEOUT", 5.0),
        max_body_mb=as_int("MAX_BODY_MB", 32),
        upstream_max_connections=upstream_max_connections,
        upstream_pool_timeout=upstream_pool_timeout,
        upstream_ipv4_only=upstream_ipv4_only,
        access_log=as_bool("ACCESS_LOG", False),
    )


# --------------------------------------------------------------------------- health --------

def _url_authority(url: str) -> str:
    """'http://spark.local:8001' -> 'spark.local:8001', for a spark node's log name."""
    return url.split("//", 1)[-1].split("/", 1)[0]


class BackendState:
    """One backend's health and catalog. `up` is meaningless until the first probe (`seen`)."""

    def __init__(self, name: str, url: str = ""):
        self.name = name
        self.url = url  # the node's own base URL; "" on local and on the spark aggregate
        self.seen = False
        self.up = False
        self.models: list[dict] = []
        self.fails = 0
        self.oks = 0
        self.last_error: str | None = None

    @property
    def ids(self) -> list[str]:
        return [m["id"] for m in self.models]


class SwitchState:
    """The spark-switch controller's last good GET /status, as received. Purely advisory: a failed
    probe keeps the previous status and only marks it stale (`ok` False); it can never move the
    local/spark backends up or down."""

    def __init__(self):
        self.status: dict | None = None   # the controller's JSON object, or None before the first hit
        self.ok: bool = False             # was the most recent probe good?
        self.last_error: str | None = None
        self.fetched_at: float | None = None

    def get(self, key: str):
        """A field of the cached status (state/current/target/phase/...), None when unknown."""
        return (self.status or {}).get(key)

    @property
    def profiles(self) -> list[dict]:
        profiles = (self.status or {}).get("profiles")
        return profiles if isinstance(profiles, list) else []

    def profile(self, name: str) -> dict | None:
        return next((p for p in self.profiles if isinstance(p, dict) and p.get("name") == name), None)


class Backends:
    """Lives on app.state.health. The httpx client is attached by the lifespan."""

    def __init__(self, config: Config):
        self.config = config
        self.client: httpx.AsyncClient | None = None
        self.local = BackendState("local")
        self.spark = BackendState("spark")  # the aggregate over spark_nodes; see _aggregate_spark
        self.spark_nodes = [
            BackendState(f"spark@{_url_authority(url)}", url=url) for url in config.spark_urls
        ]
        self.switch = SwitchState()
        self._switch_tasks: set[asyncio.Task] = set()  # keeps fire-and-forget refreshes alive

    @property
    def spark_enabled(self) -> bool:
        return bool(self.config.spark_urls)  # __post_init__ keeps this filled from spark_url too

    @property
    def switch_enabled(self) -> bool:
        return bool(self.config.spark_switch_url)

    def set_state(self, name: str, up: bool, models: list[dict]) -> None:
        """Force a backend's state (tests, or hand recovery). Resets the counters."""
        state = getattr(self, name)
        state.seen = True
        state.up = up
        state.models = [dict(m) for m in models]
        state.fails = 0
        state.oks = 0
        state.last_error = None
        log.debug("%s state set by hand: up=%s models=%s", name, up, state.ids)

    def record(self, state: BackendState, ok: bool, models: list[dict], error: str | None) -> None:
        """Apply one probe result. Unknown decides immediately; afterwards it takes HEALTH_FAIL
        consecutive failures to drop an up backend and HEALTH_OK successes to raise a down one.
        A successful probe REPLACES the catalog, so a model swap on the Spark is picked up here."""
        if ok:
            state.oks += 1
            state.fails = 0
            state.last_error = None
            new_ids = [m["id"] for m in models]
            if state.models and state.ids != new_ids:
                log.info("%s catalog: %s -> %s", state.name, ",".join(state.ids), ",".join(new_ids))
            state.models = [dict(m) for m in models]
            if not state.seen:
                state.seen = True
                state.up = True
                log.warning("%s up: models=%s", state.name, ",".join(new_ids))
            elif not state.up and state.oks >= self.config.health_ok:
                state.up = True
                log.warning("%s up: models=%s", state.name, ",".join(new_ids))
        else:
            state.fails += 1
            state.oks = 0
            state.last_error = error
            if not state.seen:
                state.seen = True
                state.up = False
                log.warning("%s down: %s", state.name, error)
            elif state.up and state.fails >= self.config.health_fail:
                state.up = False
                log.warning("%s down: %s", state.name, error)

    def _aggregate_spark(self) -> None:
        """Fold the node states into the aggregate 'spark' backend routing uses: seen/up when any
        node is, models the up nodes' catalogs in node order (deduplicated by id, first wins),
        last_error the not-None node errors joined — None while anything is up. The counters keep
        record()'s meaning (one round of probes = one aggregate probe), so with a single URL the
        aggregate behaves exactly as it did when it was probed directly."""
        nodes = self.spark_nodes
        spark = self.spark
        was_seen, was_up, was_ids = spark.seen, spark.up, spark.ids
        spark.seen = any(n.seen for n in nodes)
        spark.up = any(n.up for n in nodes)
        models: list[dict] = []
        listed: set[str] = set()
        for node in nodes:
            if node.up:
                for m in node.models:
                    if m["id"] not in listed:
                        listed.add(m["id"])
                        models.append(dict(m))
        spark.models = models
        errors = [n.last_error for n in nodes if n.last_error is not None]
        spark.last_error = None if spark.up else ("; ".join(errors) or None)
        if any(n.last_error is None for n in nodes):
            spark.oks += 1
            spark.fails = 0
        else:
            spark.fails += 1
            spark.oks = 0
        if not spark.seen:
            return
        ids = [m["id"] for m in models]
        if not was_seen or spark.up != was_up:
            if spark.up:
                log.warning("%s up: models=%s", spark.name, ",".join(ids))
            else:
                log.warning("%s down: %s", spark.name, spark.last_error)
        elif ids != was_ids:
            log.info("%s catalog: %s -> %s", spark.name, ",".join(was_ids), ",".join(ids))

    async def check_once(self) -> None:
        """Probe every enabled backend once (all in parallel, so one slow endpoint does not delay
        another's transition): local, every spark URL (each node keeps its own hysteresis), and
        the switch, which only refreshes an advisory cache. The spark results are then folded
        into the aggregate 'spark' state everything routes on."""
        if self.client is None:
            raise RuntimeError("check_once called before the lifespan attached the httpx client")
        jobs = [self._check_one(self.local, self.config.local_url, self.config.local_token)]
        for node in self.spark_nodes:
            jobs.append(self._check_one(node, node.url, self.config.spark_api_key))
        if self.switch_enabled:
            jobs.append(self._check_switch())
        await asyncio.gather(*jobs)
        if self.spark_enabled:
            self._aggregate_spark()

    async def _check_one(self, state: BackendState, base_url: str, token: str) -> None:
        timeout = httpx.Timeout(self.config.health_timeout, connect=self.config.connect_timeout)
        headers = dict(_auth_headers(token))
        headers["accept-encoding"] = "identity"
        try:
            resp = await self.client.get(f"{base_url}/v1/models", headers=headers, timeout=timeout)
        except httpx.HTTPError as exc:
            self.record(state, False, [], _short_error(exc))
            return
        if resp.status_code != 200:
            self.record(state, False, [], f"/v1/models HTTP {resp.status_code}")
            return
        try:
            data = resp.json().get("data")
            if not isinstance(data, list):
                raise ValueError("no data list")
            models = []
            for item in data:
                if isinstance(item, dict) and isinstance(item.get("id"), str):
                    models.append({"id": item["id"], "max_model_len": item.get("max_model_len")})
        except ValueError:
            self.record(state, False, [], "/v1/models returned invalid JSON")
        else:
            self.record(state, True, models, None)

    async def _check_switch(self) -> None:
        """Refresh the cached controller /status. Never raises for a transport/status/JSON failure:
        the previous status stays and is only marked stale, so neither backend is affected."""
        timeout = httpx.Timeout(self.config.health_timeout, connect=self.config.connect_timeout)
        switch_token = self.config.spark_switch_token.strip()
        headers = {"authorization": f"Bearer {switch_token}"} if switch_token else {}
        try:
            resp = await self.client.get(
                f"{self.config.spark_switch_url}/status", headers=headers, timeout=timeout
            )
        except httpx.HTTPError as exc:
            self._record_switch(False, None, _short_error(exc))
            return
        if resp.status_code != 200:
            self._record_switch(False, None, f"/status HTTP {resp.status_code}")
            return
        try:
            data = resp.json()
            if not isinstance(data, dict):
                raise ValueError("not a JSON object")
        except ValueError:
            self._record_switch(False, None, "/status returned invalid JSON")
        else:
            self._record_switch(True, data, None)

    def _record_switch(self, ok: bool, status: dict | None, error: str | None) -> None:
        self.switch.ok = ok
        self.switch.last_error = error
        if ok:
            self.switch.status = status
            self.switch.fetched_at = time.time()
        elif self.switch.status is not None:
            log.warning("switch status stale (%s), keeping the one from %.0fs ago",
                        error, time.time() - (self.switch.fetched_at or 0))

    def refresh_switch_soon(self) -> None:
        """Refresh the cached status right after an accepted switch, without making the client's
        response wait for it. The set reference keeps the task safe from garbage collection."""
        task = asyncio.create_task(self._check_switch_guarded(), name="llm-router-switch-refresh")
        self._switch_tasks.add(task)
        task.add_done_callback(self._switch_tasks.discard)

    async def _check_switch_guarded(self) -> None:
        try:
            await self._check_switch()
        except Exception as exc:  # a background refresh must never crash anything
            log.warning("switch status refresh failed: %s", _short_error(exc))

    # -- routing --------------------------------------------------------------------------

    def spark_url_for(self, model: str) -> str:
        """The base URL serving `model`: the first up node whose catalog lists it, else the first
        configured URL (set_state forces the aggregate only, so a hand-set catalog still sends
        the request somewhere sane)."""
        for node in self.spark_nodes:
            if node.up and model in node.ids:
                return node.url
        return self.config.spark_urls[0] if self.config.spark_urls else self.config.spark_url

    def spark_target(self) -> str | None:
        """What spark-large means right now: first preferred id the Spark serves, else its first."""
        ids = self.spark.ids
        for preferred in self.config.spark_prefer:
            if preferred in ids:
                return preferred
        return ids[0] if ids else None

    def resolve(self, model: str) -> tuple[str, str, str] | None:
        """-> (route, upstream model id, note) or None when the model is unknown. A note of
        'spark-down' means a spark request was downgraded to local with LOCAL_MODEL."""
        if model == ALIAS_FAST:
            return ("local", self.config.local_model, "")
        if model == self.config.local_model or model in self.local.ids:
            return ("local", model, "")
        if model == ALIAS_LARGE or (self.spark_enabled and model in self.spark.ids):
            if self.spark_enabled and self.spark.up:
                target = self.spark_target() if model == ALIAS_LARGE else model
                if target:
                    return ("spark", target, "")
            return ("local", self.config.local_model, "spark-down")
        return None


async def _health_loop(health: Backends, interval: float) -> None:
    while True:
        await asyncio.sleep(interval)
        try:
            await health.check_once()
        except Exception as exc:  # a broken probe must not kill the loop
            log.warning("health loop error: %s", _short_error(exc))


# --------------------------------------------------------------------------- helpers -------

def _short_error(exc: BaseException) -> str:
    """One short line, no request headers, so the key can never appear in it."""
    text = " ".join(str(exc).split())
    name = type(exc).__name__
    return f"{name}: {text}" if text and text != name else name


def _error_excerpt(raw: bytes, encoding: str | None, secrets: list[str]) -> str:
    """The first bytes of an upstream error body, as one log-safe line. `encoding` is the response's
    Content-Encoding header: anything but identity means these bytes are still compressed, so only
    the codec is named instead of logging undecodable garbage. Pure (no I/O) so every rule is
    directly unit-testable."""
    enc = (encoding or "").strip()
    if enc and enc.lower() != "identity":
        return f"<encoded:{enc}>"
    text = raw.decode("utf-8", errors="replace")
    for secret in secrets:
        if secret:
            text = text.replace(secret, "***")
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}", r"\1***", text)
    text = re.sub(r"sk-[A-Za-z0-9._-]{8,}", "sk-***", text)
    # One line whatever the body contained: every control character and whitespace run -> one space.
    text = re.sub(r"[\x00-\x20\x7f]+", " ", text).strip()
    if len(text) > ERROR_EXCERPT_CHARS:
        text = text[:ERROR_EXCERPT_CHARS] + "…"
    return text


def _auth_headers(token: str) -> list[tuple[str, str]]:
    """A backend's x-api-key + authorization Bearer pair, or [] when there is no token: a keyless
    vLLM must not be sent 'Bearer ' / empty x-api-key headers, which httpx rejects as illegal
    values before the request ever leaves (reporting the backend down forever)."""
    token = token.strip()
    return [("x-api-key", token), ("authorization", f"Bearer {token}")] if token else []


def _upstream_transport(config: Config, limits: httpx.Limits) -> httpx.AsyncHTTPTransport:
    """The transport every production upstream client rides on.

    macOS resolves mDNS names like spark.local to an IPv6 link-local address FIRST and IPv4
    second, while vLLM on the Spark listens on 0.0.0.0 (IPv4) only; httpx tries addresses in
    order with no happy-eyeballs fallback, so every NEW upstream connection by name first waits
    ~1 s on the unreachable IPv6 address. local_address="0.0.0.0" makes anyio resolve the remote
    host with the IPv4 family only, skipping that dead first hop.

    The limits MUST come in here, not on the AsyncClient: a client that was handed a transport
    ignores its own limits= argument, so the pool would silently fall back to httpx defaults.
    trust_env=False matches the clients (loopback/LAN only, no proxies from the environment)."""
    return httpx.AsyncHTTPTransport(
        limits=limits,
        local_address="0.0.0.0" if config.upstream_ipv4_only else None,
        trust_env=False,
    )


def _anthropic_error(
    status: int, error_type: str, message: str, headers: dict[str, str] | None = None
) -> JSONResponse:
    return JSONResponse(
        {"type": "error", "error": {"type": error_type, "message": message}},
        status_code=status, headers=headers,
    )


def _pool_full(config: Config) -> JSONResponse:
    """A full proxy pool is the router's own overload, not a backend outage: falling back to
    local would only move the queue (that send needs a slot from the same full pool), and the
    health state must not move either. A short retry is the honest answer."""
    return _anthropic_error(
        503, "overloaded_error",
        f"llm-router upstream connection pool is full "
        f"(UPSTREAM_MAX_CONNECTIONS={config.upstream_max_connections}); retry shortly",
        headers={"retry-after": "5"},
    )


def _profile_error(health: Backends, requested: str) -> JSONResponse | None:
    """Only reached where the request would otherwise be a plain 'unknown model' 400: when the name
    is a profile the switch controller knows, answer with something actionable instead. A model
    request never triggers a switch, so loading it is told to the user, not done for them."""
    if not health.switch_enabled or health.switch.profile(requested) is None:
        return None
    if health.switch.get("state") == "switching":
        target = health.switch.get("target")
        residents = health.switch.get("residents")
        # target "pair" loads every resident name at once, so each of them is "loading"
        loading_pair = target == "pair" and isinstance(residents, list) and requested in residents
        if target == requested or loading_pair:
            phase = health.switch.get("phase") or "unknown"
            return _anthropic_error(
                503, "overloaded_error",
                f"Spark is loading {requested} (phase {phase}); retry in a few minutes",
                headers={"retry-after": "60"},
            )
    current = health.switch.get("current") or "none"
    return _anthropic_error(
        400, "invalid_request_error",
        f"{requested} is a Spark profile but is not loaded (current: {current}). "
        f"Load it with: spark-model use {requested}",
    )


def _reminder_blocks(content) -> list[dict]:
    """A system message's content as the blocks to fold: text blocks are copied and wrapped in
    <system-reminder> (cache_control and any other keys ride along), non-text blocks are copied
    as-is, empty text is dropped."""
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    blocks: list[dict] = []
    for block in content if isinstance(content, list) else []:
        if not isinstance(block, dict):
            continue
        if block.get("type") != "text":
            blocks.append(dict(block))
        elif block.get("text"):
            blocks.append({**block, "text": f"<system-reminder>\n{block['text']}\n</system-reminder>"})
    return blocks


def _fold_system_messages(payload: dict) -> dict:
    """Fold role:"system" messages inside `messages` into user text blocks.

    Claude Code 2.1.x sometimes injects a {"role":"system"} message mid-conversation, and vLLM's
    Anthropic endpoint rejects that outright (400: role should be 'user' or 'assistant') while
    local (LM Studio) accepts it - so this rewrite is applied to the Spark request only. Each
    folded text is wrapped in <system-reminder> tags, mirroring Claude Code's own fallback shape.
    Returns the SAME payload when nothing needs folding, else a new payload (the input, its
    messages list and every message/block dict are left untouched): a preceding user message gets
    the blocks appended, a following one gets them prepended, otherwise a new user message is
    inserted in place; consecutive system messages share a target, in order. The top-level
    "system" field and every other key are left alone."""

    def as_blocks(content) -> list:
        if isinstance(content, str):
            return [{"type": "text", "text": content}]
        return content if isinstance(content, list) else []

    def deposit(out: list, pending: list[dict], m) -> object:
        """Attach `pending` folded blocks at the out/m boundary (see the docstring above)."""
        if out and isinstance(out[-1], dict) and out[-1].get("role") == "user":
            merged = dict(out[-1])
            merged["content"] = as_blocks(out[-1].get("content")) + pending
            out[-1] = merged
        elif isinstance(m, dict) and m.get("role") == "user":
            merged = dict(m)
            merged["content"] = pending + as_blocks(m.get("content"))
            return merged
        else:
            out.append({"role": "user", "content": pending})
        return m

    messages = payload.get("messages")
    if not isinstance(messages, list) or not any(
        isinstance(m, dict) and m.get("role") == "system" for m in messages
    ):
        return payload
    out: list = []
    pending: list[dict] = []  # blocks from one run of system messages, waiting for their target
    for m in messages:
        if isinstance(m, dict) and m.get("role") == "system":
            pending.extend(_reminder_blocks(m.get("content")))
        elif pending:
            out.append(deposit(out, pending, m))
            pending = []
        else:
            out.append(m)
    if pending:
        deposit(out, pending, None)  # trailing system messages
    return {**payload, "messages": out}


def _repair_tool_inputs(payload: dict) -> dict:
    """Rewrite assistant tool_use blocks whose "input" is not an object into object-shaped ones.

    WHY: the models behind the Spark's vLLM sometimes emit a tool call whose input is a bare
    string - e.g. the Skill tool called with input "hwpx" instead of {"skill": "hwpx"} (seen
    live 2026-11-26, qwen3-instruct, 1 of 4 hwpx runs). Claude Code keeps that block in the
    history, and on the NEXT request vLLM's Anthropic endpoint rejects the whole conversation
    (400: "input should be a valid dictionary" / content "should be a valid string"), so the
    conversation dies there. Like _fold_system_messages this rewrite is applied to the Spark
    request only: LM Studio accepted the system-role case and its handling of non-object
    tool_use inputs is unverified, so the local payload is left byte-identical.

    Each non-object input becomes an object by the first rule that applies:
      1. a string that json.loads() to an object is replaced by that object;
      2. else the tool's input_schema (from payload["tools"], matched by name) names exactly
         one property - or exactly one required property among several - and the value is
         wrapped as {that property: value}. This is what turns Skill "hwpx" into
         {"skill": "hwpx"}.
      3. else {"input": value}: any object satisfies vLLM's schema check, and by the time the
         block comes back in a request Claude Code has already run (or rejected) the call, so
         the exact shape no longer matters to anyone.
    The value in 2/3 is the string's parsed JSON when it parses to a scalar or a list (so "42"
    wraps 42), else the raw value. A missing or null input becomes {}. Blocks whose input is
    already a dict, other block types, user messages and every other payload key are never
    touched.

    Known limit: only the REQUEST is repaired. The model's malformed tool call still reaches
    Claude Code once, in the streamed response this router passes through untouched.

    Returns the SAME payload when nothing needs repairing, else a new payload (the input, its
    messages list and every message/block dict are left untouched). The one INFO line a
    repaired request logs carries the block count and tool names only, never the input values:
    those can hold user data.
    """

    def schema_for(name) -> dict | None:
        tools = payload.get("tools")
        if not isinstance(tools, list) or not isinstance(name, str):
            return None
        for tool in tools:
            if isinstance(tool, dict) and tool.get("name") == name:
                schema = tool.get("input_schema")
                return schema if isinstance(schema, dict) else None
        return None

    def wrap_property(schema: dict | None) -> str | None:
        """The one property name rule 2 wraps the value under; None when the schema does not
        narrow it to exactly one (no schema, several properties, several required)."""
        if schema is None:
            return None
        properties = schema.get("properties")
        if isinstance(properties, dict) and len(properties) == 1:
            return next(iter(properties))
        required = schema.get("required")
        if isinstance(required, list) and len(required) == 1 and isinstance(required[0], str):
            return required[0]
        return None

    def repaired_input(block: dict) -> dict | None:
        """The block's new input object, or None when the block needs no repair (a dict)."""
        value = block.get("input")
        if isinstance(value, dict):
            return None
        if isinstance(value, str):
            try:
                parsed = json.loads(value)
            except ValueError:
                pass                   # not JSON: rules 2/3 wrap the raw string
            else:
                if isinstance(parsed, dict):
                    return parsed      # rule 1
                value = parsed        # a scalar or list in string form: wrap the parsed value
        if value is None:
            return {}                  # missing or explicit null
        prop = wrap_property(schema_for(block.get("name")))
        if prop is not None:
            return {prop: value}       # rule 2
        return {"input": value}        # rule 3

    messages = payload.get("messages")
    if not isinstance(messages, list):
        return payload
    out = None          # a new messages list, allocated at the first repair
    repaired: list = []  # tool names, for the one INFO line below
    for i, message in enumerate(messages):
        if not (isinstance(message, dict) and message.get("role") == "assistant"):
            continue
        content = message.get("content")
        if not isinstance(content, list):
            continue
        blocks = None  # this message's new content list, allocated at its first repair
        for j, block in enumerate(content):
            if not (isinstance(block, dict) and block.get("type") == "tool_use"):
                continue
            new_input = repaired_input(block)
            if new_input is None:
                continue
            if blocks is None:
                blocks = list(content)
            blocks[j] = {**block, "input": new_input}
            name = block.get("name")
            repaired.append(name if isinstance(name, str) else "?")
        if blocks is not None:
            if out is None:
                out = list(messages)
            out[i] = {**message, "content": blocks}
    if out is None:
        return payload
    log.info("repaired %d tool_use input(s) that were not objects [%s]",
             len(repaired), ",".join(repaired))
    return {**payload, "messages": out}


def _upstream_request(request: Request, base_url: str, model: str, payload: dict, token: str) -> httpx.Request:
    """The client's request, rebased onto a backend: same method, path and query, everything the
    router owns replaced (auth, encoding), and only the top-level model rewritten."""
    # Raw pairs, not a mapping: repeated headers (e.g. two anthropic-beta lines) must both survive
    # the filtering. starlette 1.x Headers has no multi_items(); .raw is the scope's own list.
    headers = [
        (name.decode("latin-1"), value.decode("latin-1"))
        for name, value in request.headers.raw
        if name.decode("latin-1").lower() not in REQUEST_DROP
    ]
    headers.extend(_auth_headers(token))
    headers.append(("accept-encoding", "identity"))
    rewritten = dict(payload)
    rewritten["model"] = model
    body = json.dumps(rewritten, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    url = base_url + request.url.path
    if request.url.query:
        url += "?" + request.url.query
    return httpx.Request(request.method, url, headers=headers, content=body)


def _guard_sse(upstream: httpx.Response, path: str) -> bool:
    """Whether _stream may close this upstream stream out with a synthetic error event: only a 200
    plaintext (no content-encoding, or identity) event stream on /v1/messages, the one endpoint
    whose protocol promises a message_stop. A compressed body cannot take plaintext appended, and
    other endpoints have no such contract, so those pass through untouched."""
    encoding = upstream.headers.get("content-encoding", "").strip().lower()
    # Media type compared exactly, parsed the same way LoopbackHostMiddleware parses
    # application/json: parameters ("; charset=utf-8") are not part of the type, and startswith
    # would also admit lookalikes ("text/event-stream-custom") that are a different media type.
    media = upstream.headers.get("content-type", "").split(";", 1)[0].strip().lower()
    return (
        upstream.status_code == 200
        and media == "text/event-stream"
        and path == "/v1/messages"
        and encoding in ("", "identity")
    )


def _sse_close_error(reason: str) -> bytes:
    """The one closing `event: error` appended after an Anthropic stream that ended before
    message_stop, so the client sees a parseable end instead of a silently truncated answer."""
    message = f"upstream stream ended before message_stop ({reason})"
    body = json.dumps(
        {"type": "error", "error": {"type": "api_error", "message": message}},
        separators=(",", ":"),
    )
    return b"\n\nevent: error\ndata: " + body.encode("utf-8") + b"\n\n"


def _stream(
    upstream: httpx.Response, route_note: str, secrets: list[str] | None = None,
    guard_sse: bool = False,
) -> StreamingResponse:
    # starlette 1.x only accepts a Mapping for Response(headers=...). Headers(raw=...) satisfies
    # that contract while keeping repeated upstream headers (several set-cookie, etc.) intact.
    raw = [
        (name.encode("latin-1"), value.encode("latin-1"))
        for name, value in upstream.headers.multi_items()
        if name.lower() not in RESPONSE_DROP
    ]
    raw.append((b"x-route", route_note.encode("latin-1")))
    headers = StarletteHeaders(raw=raw)

    async def chunks():
        # What the client receives is untouched; an error body is only PEEKED AT in passing: for
        # status >= 400 the first ERROR_CAPTURE bytes are copied aside so the finally below can log
        # WHY the upstream said no - the proxied line only carries status=400, and vLLM's reason
        # ("'max_tokens' ... is too large") is unreadable afterwards without this.
        buf = bytearray() if upstream.status_code >= 400 else None
        tail = b"\n"   # last SSE_TAIL_KEEP bytes, so a marker split across two chunks is still
        # found; the "\n" seed also completes a marker whose stream STARTS with "event: ..."
        ended = False  # the forwarded bytes already carried message_stop or an error event

        def close_out(reason: str) -> bytes:
            # One warning per cut stream, with the words that find it in the log afterwards.
            log.warning(
                "upstream stream ended before message_stop (%s), appended error event route=%s",
                reason, route_note,
            )
            return _sse_close_error(reason)

        try:
            async for chunk in upstream.aiter_raw():
                if buf is not None and len(buf) < ERROR_CAPTURE:
                    buf.extend(chunk[:ERROR_CAPTURE - len(buf)])
                if guard_sse and not ended:
                    window = tail + chunk
                    ended = any(marker in window for marker in SSE_END_MARKERS)
                    tail = window[-SSE_TAIL_KEEP:]
                yield chunk
            if guard_sse and not ended:  # a clean end, just early: same close-out, reason says so
                yield close_out("closed")
        except httpx.HTTPError as exc:
            # The upstream died mid-stream (a Spark slot torn down mid-generation). On the guarded
            # stream the deltas are already on the wire, so no retry can take them back: close out
            # with the error event and end normally. Anywhere the close-out does not apply -
            # unguarded stream, or an end marker already forwarded - the exception propagates
            # unchanged, aborting the response exactly as it did before this guard existed.
            # CancelledError / GeneratorExit (a client disconnect) is not an HTTPError and still
            # propagates.
            if guard_sse and not ended:
                yield close_out(_short_error(exc))
            else:
                raise
        finally:
            if buf is not None:
                log.warning(
                    "upstream error route=%s status=%s body=%s", route_note, upstream.status_code,
                    _error_excerpt(bytes(buf), upstream.headers.get("content-encoding"), secrets or []),
                )
            # Also runs when the client disconnects mid-stream, closing the upstream connection.
            await upstream.aclose()

    return StreamingResponse(chunks(), status_code=upstream.status_code, headers=headers)


# --------------------------------------------------------------------------- endpoints -----

async def _proxy(request: Request):
    config: Config = request.app.state.config
    health: Backends = request.app.state.health
    client: httpx.AsyncClient = request.app.state.client
    started = time.monotonic()

    limit = config.max_body_mb * 1024 * 1024
    too_large = _anthropic_error(
        413, "invalid_request_error", f"request body exceeds MAX_BODY_MB={config.max_body_mb}"
    )
    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > limit:
        return too_large
    parts: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        size += len(chunk)
        if size > limit:
            return too_large
        parts.append(chunk)
    raw = b"".join(parts)

    try:
        payload = json.loads(raw)
    except ValueError:
        return _anthropic_error(400, "invalid_request_error", "request body is not valid JSON")
    if not isinstance(payload, dict) or not isinstance(payload.get("model"), str) or not payload["model"]:
        return _anthropic_error(
            400, "invalid_request_error", "request body must be a JSON object with a model field"
        )
    requested = payload["model"]

    resolved = health.resolve(requested)
    if resolved is None:
        profile_error = _profile_error(health, requested)
        if profile_error is not None:
            return profile_error
        return _anthropic_error(
            400, "invalid_request_error",
            f"unknown model: {requested} (GET /v1/models lists what this router serves)",
        )
    route, target, note = resolved
    route_note = f"{route} ({note})" if note else route

    upstream = None
    if route == "spark":
        # Both rewrites are spark-only (the local payload goes out unchanged): vLLM's Anthropic
        # endpoint 400s on mid-conversation system roles and on non-object tool_use inputs,
        # while LM Studio has accepted everything seen so far. Fold first, then repair - they
        # touch disjoint parts of the payload (system->user messages vs assistant blocks).
        spark_req = _upstream_request(
            request, health.spark_url_for(target), target,
            _repair_tool_inputs(_fold_system_messages(payload)), config.spark_api_key,
        )
        try:
            # stream=True: the response is committed to the client as soon as the upstream headers
            # arrive, without waiting for a first body chunk (long prefill can be silent for a while).
            upstream = await client.send(spark_req, stream=True)
        except httpx.PoolTimeout:
            # Before httpx.HTTPError: overload is not an outage, so no failover, no health change.
            log.warning("spark send queued out (pool full, UPSTREAM_MAX_CONNECTIONS=%d)",
                        config.upstream_max_connections)
            return _pool_full(config)
        except (
            httpx.ConnectError, httpx.ConnectTimeout, httpx.ReadError,
            httpx.RemoteProtocolError, httpx.WriteError,
        ) as exc:
            # A drop BEFORE any response header - a refused connect, or the connection dying while
            # the request was in flight (ReadError / RemoteProtocolError / WriteError, seen live
            # during a Spark slot teardown) - means nothing reached the client yet, so it is
            # retried on local exactly like a refused connect. One dropped request is not a health
            # verdict, so the state is untouched. ReadTimeout and every other HTTPError still 502
            # below: the Spark may still be running the request (same reason 504 is not retried).
            log.info("spark connection lost before any response header, will retry on local: %s",
                     _short_error(exc))
        except httpx.HTTPError as exc:
            return _anthropic_error(502, "api_error", f"spark request failed: {_short_error(exc)}")
        else:
            if upstream.status_code in RETRY_STATUSES:
                await upstream.aclose()
                upstream = None
        if upstream is None:
            route, target, route_note = "local", config.local_model, "local (retry)"

    if upstream is None:
        local_req = _upstream_request(request, config.local_url, target, payload, config.local_token)
        try:
            upstream = await client.send(local_req, stream=True)
        except httpx.PoolTimeout:
            # Same as the spark branch: a busy pool is overload, not "local unreachable".
            log.warning("local send queued out (pool full, UPSTREAM_MAX_CONNECTIONS=%d)",
                        config.upstream_max_connections)
            return _pool_full(config)
        except httpx.HTTPError as exc:
            log.warning("local request failed: %s", _short_error(exc))
            return _anthropic_error(502, "api_error", f"local backend unreachable: {_short_error(exc)}")

    log.info(
        "%s %s model=%s route=%s id=%s status=%s %dms",
        request.method, request.url.path, requested, route_note, target, upstream.status_code,
        round((time.monotonic() - started) * 1000),
    )
    # Every configured secret, stripped: an error body can echo one back, so _stream masks each.
    secrets = [
        s.strip() for s in (config.spark_api_key, config.local_token, config.spark_switch_token)
        if s.strip()
    ]
    return _stream(upstream, route_note, secrets, guard_sse=_guard_sse(upstream, request.url.path))


async def get_health(request: Request):
    health: Backends = request.app.state.health
    return {
        "ok": True,
        "local": {
            "up": health.local.up,
            "models": health.local.models,
            "last_error": health.local.last_error,
        },
        "spark": {
            "enabled": health.spark_enabled,
            "up": health.spark.up,
            "models": health.spark.models,
            "large": health.spark_target(),
            "last_error": health.spark.last_error,
            "nodes": [  # one entry per configured URL; never any key
                {"url": n.url, "up": n.up, "models": n.ids, "last_error": n.last_error}
                for n in health.spark_nodes
            ],
        },
        "switch": {  # the spark-switch controller; no token ever appears here
            "configured": health.switch_enabled,
            "ok": health.switch.ok,
            "state": health.switch.get("state"),
            "current": health.switch.get("current"),
        },
    }


async def get_models(request: Request):
    health: Backends = request.app.state.health
    config: Config = request.app.state.config
    data = [
        {"id": ALIAS_LARGE, "type": "model", "route": "spark", "target": health.spark_target()},
        {"id": ALIAS_FAST, "type": "model", "route": "local", "target": config.local_model},
    ]
    for backend, route in ((health.local, "local"), (health.spark, "spark")):
        for m in backend.models:
            entry = {"id": m["id"], "type": "model", "route": route, "target": m["id"]}
            if m.get("max_model_len") is not None:
                entry["max_model_len"] = m["max_model_len"]
            data.append(entry)
    if health.switch_enabled:
        # Profiles the controller could load but the Spark is not serving right now, so they are
        # discoverable ("spark-model use <name>") instead of silently unknown.
        listed = {entry["id"] for entry in data}
        for profile in health.switch.profiles:
            name = profile.get("name") if isinstance(profile, dict) else None
            if not isinstance(name, str) or not name or name in listed:
                continue  # already served by a backend, or malformed
            data.append(
                {"id": name, "type": "model", "route": "spark (not loaded)", "kind": profile.get("kind")}
            )
            listed.add(name)
    return {"data": data, "object": "list"}


async def get_spark_status(request: Request):
    health: Backends = request.app.state.health
    if not health.switch_enabled:
        return _anthropic_error(404, "invalid_request_error", "spark switch not configured")
    return {
        "switch": health.switch.status,       # the controller's last good JSON, or null
        "switch_ok": health.switch.ok,        # False = that JSON is stale
        "spark": {"up": health.spark.up, "models": health.spark.models},
    }


async def post_spark_switch(request: Request):
    config: Config = request.app.state.config
    health: Backends = request.app.state.health
    # The control pool, never the proxy one: a saturated proxy pool must not block switching.
    client: httpx.AsyncClient = request.app.state.control_client
    if not health.switch_enabled:
        return _anthropic_error(404, "invalid_request_error", "spark switch not configured")

    too_large = _anthropic_error(
        400, "invalid_request_error", f"request body exceeds {SWITCH_BODY_LIMIT} bytes"
    )
    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > SWITCH_BODY_LIMIT:
        return too_large
    raw = await request.body()
    if len(raw) > SWITCH_BODY_LIMIT:
        return too_large
    try:
        payload = json.loads(raw)
    except ValueError:
        return _anthropic_error(400, "invalid_request_error", "request body is not valid JSON")
    if not isinstance(payload, dict) or not isinstance(payload.get("profile"), str) or not payload["profile"]:
        return _anthropic_error(
            400, "invalid_request_error", "request body must be a JSON object with a profile field"
        )

    switch_token = config.spark_switch_token.strip()
    headers = {"authorization": f"Bearer {switch_token}"} if switch_token else {}
    try:
        # A switch can take a moment to be accepted: connect stays short, the whole call is capped
        # at 30 s (the loading itself happens after the controller has answered 202).
        resp = await client.post(
            f"{config.spark_switch_url}/switch", json={"profile": payload["profile"]},
            headers=headers, timeout=httpx.Timeout(30.0, connect=config.connect_timeout),
        )
    except httpx.HTTPError as exc:
        log.warning("switch POST failed: %s", _short_error(exc))
        return _anthropic_error(502, "api_error", f"spark switch controller unreachable: {_short_error(exc)}")
    if resp.status_code in (200, 202):
        health.refresh_switch_soon()  # pick the new state up now, not at the next probe
    return Response(
        content=resp.content, status_code=resp.status_code,
        media_type=resp.headers.get("content-type", "application/json"),
    )


# --------------------------------------------------------------------------- app -----------

def _origin_host(origin: str) -> str | None:
    """The host of an Origin header value, or None when it has no http(s) origin
    ('null', chrome-extension://..., garbage). userinfo@ is ignored, as browsers
    never send it but a forger might."""
    scheme, _, rest = origin.partition(":")
    if scheme.lower() not in ("http", "https") or not rest:
        return None
    host = rest[2:] if rest.startswith("//") else rest
    host = host.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if "@" in host:
        host = host.rsplit("@", 1)[1]
    if host.startswith("["):  # IPv6 literal: [::1]:1240
        host = host[1:].split("]", 1)[0]
    else:
        host = host.split(":", 1)[0]
    return host.lower() or None


class LoopbackHostMiddleware:
    """Three browser-shaped attacks are stopped before any route runs:

    1. DNS rebinding: the Host header must be the router's own loopback address.
    2. Cross-origin POST from a malicious page: browsers always send Origin on a
       cross-origin POST (CLI/SDK clients do not); if it is there at all, its host
       must be loopback too — a page on https://evil.example cannot drive the
       router even though no CORS preflight happens for text/plain.
    3. Content-Type smuggling: a POST must be application/json, so a form or
       text/plain body a page can send without preflight is rejected with 415
       before the handler (or the switch controller behind it) is reached."""

    def __init__(self, app, allowed_hosts: set[str]):
        self.app = app
        self.allowed = {h.lower() for h in allowed_hosts}

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = scope.get("headers", [])
            host = next((v.decode("latin-1") for k, v in headers if k == b"host"), "")
            if host.lower() not in self.allowed:
                response = _anthropic_error(
                    403, "invalid_request_error",
                    f"bad Host header; this router only answers {', '.join(sorted(self.allowed))}",
                )
                await response(scope, receive, send)
                return
            origin = next((v.decode("latin-1") for k, v in headers if k == b"origin"), "")
            if origin and _origin_host(origin) not in LOOPBACK_HOSTS:
                response = _anthropic_error(
                    403, "invalid_request_error",
                    "bad Origin header; this router only accepts loopback origins",
                )
                await response(scope, receive, send)
                return
            if scope["method"] == "POST":
                content_type = next(
                    (v.decode("latin-1") for k, v in headers if k == b"content-type"), ""
                )
                media = content_type.split(";", 1)[0].strip().lower()
                if media != "application/json":
                    response = _anthropic_error(
                        415, "invalid_request_error",
                        "POST requests must have Content-Type: application/json",
                    )
                    await response(scope, receive, send)
                    return
        await self.app(scope, receive, send)


def create_app(
    config: Config,
    transport: httpx.AsyncBaseTransport | None = None,
    start_health_loop: bool = True,
) -> FastAPI:
    """The transport parameter is how tests hand in a MockTransport; production leaves it None.
    The app is only created here, never at import time."""
    health = Backends(config)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # One Limits object per client, handed to whichever path applies: with an explicit
        # transport the client ignores its own limits=, so in production the sizes must ride on
        # the transport itself (see _upstream_transport).
        # Sized for concurrent streams: httpx's default 100 filled under load and requests then
        # failed as PoolTimeout instead of waiting their turn.
        proxy_limits = httpx.Limits(
            max_connections=config.upstream_max_connections,
            max_keepalive_connections=min(64, config.upstream_max_connections),
        )
        # Probes and control calls get their own tiny pool: when every proxy connection is busy
        # streaming, they must still get one at once, or overload reads as an outage (the probe's
        # PoolTimeout would mark backends down and switch POSTs would hang).
        control_limits = httpx.Limits(max_connections=8, max_keepalive_connections=4)
        # `transport` is how tests hand in a MockTransport (pool limits irrelevant there);
        # production builds a real IPv4-only transport per client with its own limits.
        proxy_transport = (
            transport if transport is not None else _upstream_transport(config, proxy_limits)
        )
        control_transport = (
            transport if transport is not None else _upstream_transport(config, control_limits)
        )
        client = httpx.AsyncClient(
            transport=proxy_transport,
            # Proxied generation can be long: connect is short, read is unbounded.
            timeout=httpx.Timeout(
                None, connect=config.connect_timeout, write=60.0, pool=config.upstream_pool_timeout
            ),
            trust_env=False,  # loopback and LAN only: no proxies from the environment
        )
        control_client = httpx.AsyncClient(
            transport=control_transport,
            trust_env=False,
            timeout=httpx.Timeout(config.health_timeout, connect=config.connect_timeout),
        )
        app.state.client = client
        app.state.control_client = control_client
        health.client = control_client
        try:
            # One probe before serving, so the first request already knows both catalogs.
            await asyncio.wait_for(health.check_once(), timeout=config.health_timeout + 1.0)
        except Exception as exc:  # a probe that hangs must not block startup
            log.warning("startup health check failed: %s", _short_error(exc))
        task = None
        if start_health_loop:
            task = asyncio.create_task(_health_loop(health, config.health_interval), name="llm-router-health")
        try:
            yield
        finally:
            if task is not None:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task
            # Each close runs even if the other raises: one stuck pool must not leak the other.
            with suppress(Exception):
                await client.aclose()
            with suppress(Exception):
                await control_client.aclose()

    app = FastAPI(lifespan=lifespan, openapi_url=None, docs_url=None, redoc_url=None)
    app.state.config = config
    app.state.health = health
    app.add_middleware(
        LoopbackHostMiddleware,
        allowed_hosts={f"127.0.0.1:{config.port}", f"localhost:{config.port}", f"[::1]:{config.port}"},
    )

    for path in ("/v1/messages", "/v1/messages/count_tokens", "/v1/chat/completions", "/v1/messages/{tail:path}"):
        app.add_api_route(path, _proxy, methods=["POST"])

    app.add_api_route("/health", get_health, methods=["GET"])
    app.add_api_route("/v1/models", get_models, methods=["GET"])
    app.add_api_route("/v1/spark/status", get_spark_status, methods=["GET"])
    app.add_api_route("/v1/spark/switch", post_spark_switch, methods=["POST"])

    @app.exception_handler(StarletteHTTPException)
    async def http_exception(request: Request, exc: StarletteHTTPException):
        # FastAPI's own 404/405 (and anything else unmatched) in the Anthropic error shape.
        return _anthropic_error(exc.status_code, "invalid_request_error", str(exc.detail))

    return app


# --------------------------------------------------------------------------- fd limit ------

def _fd_needed(config: Config) -> int:
    """Open descriptors the router should be allowed to hold: two sockets per proxied stream
    (client side + upstream side) plus a baseline for the listener, logs, probes, interpreter."""
    return max(4096, 2 * config.upstream_max_connections + 256)


def _raise_fd_limit(needed: int, log) -> int:
    """Raise the soft RLIMIT_NOFILE to `needed`, never above the hard limit. Returns the soft
    limit now in effect; failures only log, they never raise.

    WHY: every proxied stream holds two descriptors (client socket + upstream socket), so
    macOS's default soft limit of 256 is exhausted at roughly 128 concurrent streams - past
    that, socket() itself fails and both backends report ConnectError at the same moment.
    Called from main() only: create_app runs many times per test process and must not touch
    the real process-wide limit."""
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft >= needed:
        return soft
    target = needed if hard == resource.RLIM_INFINITY else min(needed, hard)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except (ValueError, OSError):
        log.warning("could not raise open-file soft limit %d -> %d: keeping %d; "
                    "concurrent streams above ~%d may fail to connect", soft, target, soft, soft // 2)
        return soft
    if target < needed:
        log.warning("open-file soft limit raised %d -> %d but the hard limit caps it below the "
                    "wanted %d; raise the hard limit (launchd limit.maxfiles / ulimit -Hn) "
                    "for more concurrent streams", soft, target, needed)
    else:
        log.info("raised open-file limit %d -> %d", soft, target)
    return target


def _setup_logging() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    # The 10-second /v1/models probes made httpx emit one INFO line each (~1.8 MB of router log a
    # day, nearly all of it health-probe noise). WARNING keeps real connection failures visible and
    # drops the per-request chatter; httpcore, httpx's transport layer underneath, gets the same.
    for name in ("httpx", "httpcore"):
        logging.getLogger(name).setLevel(logging.WARNING)


def main() -> None:
    _setup_logging()
    try:
        config = load_config()
    except ConfigError as exc:
        print(f"llm-router: {exc}", file=sys.stderr)
        sys.exit(2)
    _raise_fd_limit(_fd_needed(config), log)
    uvicorn.run(
        create_app(config), host=config.host, port=config.port,
        log_level="info", proxy_headers=False, server_header=False,
        access_log=config.access_log,  # off by default: the router logs one line per proxied request itself
    )


if __name__ == "__main__":
    main()
