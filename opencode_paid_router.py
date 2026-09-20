#!/usr/bin/env python3
"""OpenCode paid multi-account router.

Round-robins /v1/chat/completions across N isolated opencode serve instances,
each backed by a different paid account (Go or Zen key). Each account lives in
its own data dir (accounts/<N>/', own auth.json, own opencode.db), so requests
hit the workspace of exactly one account per request.

Env:
  OPENCODE_SERVE_PORTS  comma-separated serve ports  (e.g. "4091,4092,4093")
  OPENCODE_BRIDGE_PORT  listen port                  (default 4060)
  OPENCODE_BRIDGE_TOKEN bearer token (required; installed via bridge.env)
  OPENCODE_TIMEOUT      per-request upstream timeout (default 300)
  OPENCODE_PROVIDER     providerID sent to opencode (default "opencode-go",
                        use "opencode" for Zen-key accounts)

API: same OpenAI-compatible surface as opencode_bridge (models / chat
completions / non-streaming + single-chunk SSE).
"""
import http.server, json, urllib.request, os, secrets, time, sys
from urllib.error import HTTPError

SERVE_PORTS = [int(p) for p in
               os.environ.get("OPENCODE_SERVE_PORTS", "").split(",") if p.strip()]
PORT = int(os.environ.get("OPENCODE_BRIDGE_PORT", "4060"))
BRIDGE_TOKEN = os.environ.get("OPENCODE_BRIDGE_TOKEN", "")
PROVIDER = os.environ.get("OPENCODE_PROVIDER", "opencode-go")
TIMEOUT = int(os.environ.get("OPENCODE_TIMEOUT", "300"))

if not SERVE_PORTS:
    sys.exit("OPENCODE_SERVE_PORTS not set")

_rr = {"i": 0}


def next_port():
    i = _rr["i"] % len(SERVE_PORTS)
    _rr["i"] += 1
    return SERVE_PORTS[i]


def _content_to_text(content):
    if isinstance(content, str):
        return content
    return "".join(c.get("text", "") for c in content
                   if isinstance(c, dict) and c.get("type") == "text")


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


def provider_for(port, fallback=None):
    """Which opencode provider this serve instance accepts. Any auth.json with a
    Go key exposes just that; zen-only accounts give 'opencode'. Cheap test:
    /config shows 'providers' only when a workspace key is resolvable; when empty
    fall back to trying providers in sequence at request time."""
    try:
        cfg = json.loads(urllib.request.urlopen(
            f"http://127.0.0.1:{port}/config", timeout=5).read())
        provs = cfg.get("providers", {})
        if isinstance(provs, dict):
            for pid in ("opencode-go", "opencode"):
                if pid in provs:
                    return pid
            if provs:
                return sorted(provs)[0]
    except Exception:
        pass
    return fallback or PROVIDER


PROVIDER_CANDIDATES = ["opencode-go", "opencode"]


def complete_on(port, model, messages):
    base = f"http://127.0.0.1:{port}"
    req = urllib.request.Request(base + "/session",
                                 data=json.dumps({"title": "paid-router"}).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    sid = json.loads(urllib.request.urlopen(req, timeout=30).read())["id"]
    last = None
    cand = [provider_for(port)]
    for pid in PROVIDER_CANDIDATES:
        if pid not in cand:
            cand.append(pid)
    for pid in cand:
        body = {"parts": [{"type": "text", "text": build_prompt(messages)}],
                "model": {"providerID": pid, "modelID": model}}
        req = urllib.request.Request(base + f"/session/{sid}/message",
                                     data=json.dumps(body).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        try:
            resp = json.loads(urllib.request.urlopen(req, timeout=TIMEOUT).read())
            text = "".join(p.get("text", "") for p in resp.get("parts", []) if p.get("type") == "text").strip()
            if not text:
                text = "".join(p.get("text", "") for p in resp.get("parts", []) if p.get("type") == "reasoning").strip()
            return text
        except HTTPError as e:
            detail = e.read().decode(errors="replace")[:200]
            last = RuntimeError(f"serve:{port} {pid} {e.code}: {detail}")
            continue  # try next provider on this instance
    raise last or RuntimeError(f"serve:{port} failed")


def list_models():
    models = set()
    for port in SERVE_PORTS:
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{port}/config")
            cfg = json.loads(urllib.request.urlopen(req, timeout=10).read())
            provs = cfg.get("providers", {})
            if isinstance(provs, dict):
                for pid, p in provs.items():
                    if pid.startswith("opencode"):
                        models.update((p.get("models") or {}).keys())
        except Exception:
            continue
    return sorted(models) or ["glm-5.3-flash"]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authed(self):
        return self.headers.get("Authorization", "") == f"Bearer {BRIDGE_TOKEN}"

    def do_GET(self):
        if not self._authed():
            self._send({"error": "unauthorized"}, 401)
            return
        if self.path.startswith("/v1/models"):
            self._send({"object": "list",
                        "data": [{"id": m, "object": "model"} for m in list_models()]})
        elif self.path in ("/health", "/v1/health"):
            up = [p for p in SERVE_PORTS if self._ping(p)]
            self._send({"ok": bool(up), "accounts_total": len(SERVE_PORTS),
                        "accounts_up": len(up), "ports_up": up})
        else:
            self._send({"error": "not found"}, 404)

    def _ping(self, port):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/config", timeout=3).read()
            return True
        except Exception:
            return False

    def do_POST(self):
        if not self._authed():
            self._send({"error": "unauthorized"}, 401)
            return
        if self.path != "/v1/chat/completions":
            self._send({"error": "not found"}, 404)
            return
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        except Exception:
            self._send({"error": {"message": "bad json"}}, 400)
            return
        model = body.get("model", "")
        messages = body.get("messages", [])
        text, used = None, None
        last_err = None
        # Round-robin start, then failover through the rest.
        order = SERVE_PORTS[_rr["i"] % len(SERVE_PORTS):] + SERVE_PORTS[:_rr["i"] % len(SERVE_PORTS)]
        _rr["i"] += 1
        for port in order:
            try:
                text = complete_on(port, model, messages)
                used = port
                break
            except Exception as e:
                last_err = e
        if text is None:
            sys.stderr.write(f"[router] all accounts failed; last: {last_err}\n")
            sys.stderr.flush()
            try:
                self._send({"error": {"message": f"all accounts failed; last: {last_err}",
                                      "type": "upstream"}}, 502)
            except BrokenPipeError:
                pass
            return
        usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
        if body.get("stream"):
            self._send_stream(model, text)
        else:
            self._send({"id": f"chatcmpl-{secrets.token_hex(8)}",
                        "object": "chat.completion", "created": int(time.time()),
                        "model": model,
                        "choices": [{"index": 0,
                                     "message": {"role": "assistant", "content": text},
                                     "finish_reason": "stop"}],
                        "usage": usage, "account_port": used})

    def _send_stream(self, model, text):
        cid = f"chatcmpl-{secrets.token_hex(8)}"
        def chunk(delta, finish=None):
            return {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": model,
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        lines = "".join("data: " + json.dumps(e) + "\n\n" for e in (
            chunk({"role": "assistant", "content": text}),
            chunk({}, "stop"))) + "data: [DONE]\n\n"
        data = lines.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    from http.server import ThreadingHTTPServer
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"opencode paid router on http://127.0.0.1:{PORT}/v1 "
          f"(accounts: {','.join(str(p) for p in SERVE_PORTS)})", flush=True)
    srv.serve_forever()
