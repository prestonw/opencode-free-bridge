#!/usr/bin/env python3
"""OpenCode free-tier bridge: exposes an OpenAI-compatible /v1/chat/completions
that routes to the local `opencode serve` instance (which is "within OpenCode"
and can use the keyless free models that a direct API call 403s).

Env:
  OPENCODE_SERVER_URL      (default http://127.0.0.1:4090)
  OPENCODE_BRIDGE_PORT     (default 4059)
  OPENCODE_BRIDGE_TOKEN    bearer token; REQUIRED in service mode (installs write
                           one to the env file), random otherwise (printed to stdout)
  OPENCODE_TIMEOUT         per-request upstream timeout seconds (default 300)
  OPENCODE_MODEL_REFRESH   re-fetch the model list every N seconds (default 3600, 0=off)
"""
import http.server, json, urllib.request, os, sys, secrets, time, socket
from urllib.error import HTTPError

OP_BASE = os.environ.get("OPENCODE_SERVER_URL", "http://127.0.0.1:4090").rstrip("/")
PORT = int(os.environ.get("OPENCODE_BRIDGE_PORT", "4059"))
BRIDGE_TOKEN = os.environ.get("OPENCODE_BRIDGE_TOKEN", "") or secrets.token_urlsafe(24)
SVC_MODE = bool(os.environ.get("OPENCODE_BRIDGE_TOKEN"))  # token pinned by service mgr
TIMEOUT = int(os.environ.get("OPENCODE_TIMEOUT", "300"))

# Static fallback list; superseded by a live fetch from opencode's /config/models.
FALLBACK_MODELS = [
    "ling-3.0-flash-fin-free",
    "mimo-v2.5-free",
    "muse-spark-1.2-contributor-free",
    "muse-spark-1.3-contributor-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
    "big-pickle",
]

MODELS = list(FALLBACK_MODELS)
MODELS_TS = 0.0


def refresh_models(force=False):
    """Pull the live free-model list from opencode serve.

    opencode exposes GET /config/models returning a flat list of
    {id, ..., cost: {free: true, ...}} (shape varies by version; be tolerant).
    On any failure keep the previous list (starts as the static fallback).
    """
    global MODELS, MODELS_TS
    if not force and time.time() - MODELS_TS < int(os.environ.get("OPENCODE_MODEL_REFRESH", "3600")):
        return MODELS
    try:
        # 1.79+ shape: POST /config gives provider.model map
        req = urllib.request.Request(OP_BASE + "/config", method="GET")
        req.add_header("Content-Type", "application/json")
        cfg = json.loads(urllib.request.urlopen(req, timeout=10).read())
        found = set()
        for prov in cfg.get("providers", {}).values() if isinstance(cfg.get("providers"), dict) else []:
            for m in (prov.get("models") or {}):
                if m.endswith("-free") or m == "big-pickle":
                    found.add(m)
        if found:
            MODELS = sorted(found)
    except Exception:
        # 1.18 shape: GET /model lists {providerID, id, free...}
        try:
            req = urllib.request.Request(OP_BASE + "/model", method="GET")
            listing = json.loads(urllib.request.urlopen(req, timeout=10).read())
            found = set()
            for row in listing:
                mid = row.get("id") or row.get("modelID") or ""
                if (row.get("providerID") or "").startswith("opencode") and (
                        mid.endswith("-free") or mid == "big-pickle"):
                    found.add(mid)
            if found:
                MODELS = sorted(found)
        except Exception:
            pass  # keep previous MODELS
    MODELS_TS = time.time()
    return MODELS


def _content_to_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                out.append(c.get("text", ""))
        return " ".join(out)
    return str(content)


def build_prompt(messages):
    lines = []
    for m in messages or []:
        role = m.get("role", "user")
        text = _content_to_text(m.get("content", ""))
        if not text:
            continue
        if role == "system":
            lines.append(f"System instructions: {text}")
        elif role == "assistant":
            lines.append(f"Assistant: {text}")
        else:
            lines.append(f"User: {text}")
    return "\n\n".join(lines)


def opencode_new_session():
    req = urllib.request.Request(OP_BASE + "/session",
                                 data=json.dumps({"title": "hermes-bridge"}).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    return json.loads(urllib.request.urlopen(req, timeout=30).read())["id"]


def opencode_complete(model, messages):
    sid = opencode_new_session()
    body = {
        "parts": [{"type": "text", "text": build_prompt(messages)}],
        "model": {"providerID": "opencode", "modelID": model},
    }
    req = urllib.request.Request(OP_BASE + f"/session/{sid}/message",
                                 data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=TIMEOUT).read())
    except HTTPError as e:
        detail = e.read().decode(errors="replace")[:500]
        raise RuntimeError(f"opencode {e.code}: {detail}") from e
    text_parts = [p.get("text", "") for p in resp.get("parts", []) if p.get("type") == "text"]
    text = "".join(text_parts).strip()
    if not text:
        text = "".join(p.get("text", "") for p in resp.get("parts", []) if p.get("type") == "reasoning").strip()
    return text


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "opencode-bridge/2"

    def _send(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        if not BRIDGE_TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {BRIDGE_TOKEN}"

    def do_GET(self):
        if not self._authorized():
            self._send({"error": "unauthorized"}, 401)
            return
        if self.path.startswith("/v1/models"):
            self._send({"object": "list", "data": [{"id": m, "object": "model"}
                                                   for m in refresh_models()]})
        elif self.path in ("/health", "/v1/health"):
            ok = True
            try:
                refresh_models(force=True)
            except Exception:
                pass  # model refresh failure does not make the bridge unhealthy
            self._send({"ok": ok, "models": len(MODELS), "upstream": OP_BASE})
        else:
            self._send({"error": "not found"}, 404)

    def _send_stream(self, model, text):
        # Single-shot SSE: whole content in one chunk (the upstream has no
        # incremental stream in blocking mode), then finish, then [DONE].
        cid = f"chatcmpl-{secrets.token_hex(8)}"
        def chunk(delta, finish=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        lines = "".join("data: " + json.dumps(e) + "\n\n" for e in (
            chunk({"role": "assistant", "content": text}),
            chunk({}, "stop"),
        )) + "data: [DONE]\n\n"
        data = lines.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if not self._authorized():
            self._send({"error": "unauthorized"}, 401)
            return
        if self.path != "/v1/chat/completions":
            self._send({"error": "not found"}, 404)
            return
        n = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            self._send({"error": {"message": "bad json"}}, 400)
            return
        model = body.get("model", "")
        messages = body.get("messages", [])
        if model not in refresh_models() and model not in MODELS:
            self._send({"error": {"message": f"unknown free model: {model}",
                                  "available": MODELS}}, 400)
            return
        try:
            text = opencode_complete(model, messages)
        except Exception as e:
            self._send({"error": {"message": f"opencode error: {e}", "type": "upstream"}}, 502)
            return
        usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        if body.get("stream"):
            self._send_stream(model, text)
            return
        self._send({
            "id": f"chatcmpl-{secrets.token_hex(8)}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                         "finish_reason": "stop"}],
            "usage": usage,
        })

    def log_message(self, format, *args):
        srv_mode = " svc" if SVC_MODE else ""
        sys.stderr.write(f"[bridge{srv_mode}] {self.addressstring()} {format % args}\n")

    def addressstring(self):
        return f"{self.client_address[0]}" if self.client_address else "-"


class HealthServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32


if __name__ == "__main__":
    srv = HealthServer(("127.0.0.1", PORT), Handler)
    refresh_models(force=True)  # may keep FALLBACK_MODELS if opencode is booting
    print(f"opencode free bridge v2 on http://127.0.0.1:{PORT}/v1 (upstream {OP_BASE})", flush=True)
    print(f"models: {', '.join(MODELS)}", flush=True)
    if not os.environ.get("OPENCODE_BRIDGE_TOKEN"):
        print(f"auth token (set OPENCODE_BRIDGE_TOKEN to pin): {BRIDGE_TOKEN}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
