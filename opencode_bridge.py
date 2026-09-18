#!/usr/bin/env python3
"""OpenCode free-tier bridge: exposes an OpenAI-compatible /v1/chat/completions
that routes to the local `opencode serve` instance (which is "within OpenCode"
and can use the keyless free models that a direct API call 403s).

Usage: OPENCODE_BRIDGE_PORT=4059 python3 opencode_bridge.py
"""
import http.server, json, urllib.request, os, sys, secrets

OP_BASE = os.environ.get("OPENCODE_SERVER_URL", "http://127.0.0.1:4090")
PORT = int(os.environ.get("OPENCODE_BRIDGE_PORT", "4059"))
BRIDGE_TOKEN = os.environ.get("OPENCODE_BRIDGE_TOKEN", "") or secrets.token_urlsafe(24)

FREE_MODELS = [
    "ling-3.0-flash-fin-free",
    "mimo-v2.5-free",
    "muse-spark-1.2-contributor-free",
    "muse-spark-1.3-contributor-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
    "big-pickle",
]


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


def opencode_complete(model, messages):
    # create a fresh session (stateless, full history in the prompt)
    req = urllib.request.Request(OP_BASE + "/session",
                                 data=json.dumps({"title": "hermes-bridge"}).encode(),
                                 method="POST")
    req.add_header("Content-Type", "application/json")
    sid = json.loads(urllib.request.urlopen(req, timeout=30).read())["id"]

    body = {
        "parts": [{"type": "text", "text": build_prompt(messages)}],
        "model": {"providerID": "opencode", "modelID": model},
    }
    req = urllib.request.Request(OP_BASE + f"/session/{sid}/message",
                                 data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    resp = json.loads(urllib.request.urlopen(req, timeout=300).read())

    text_parts = [p.get("text", "") for p in resp.get("parts", []) if p.get("type") == "text"]
    text = "".join(text_parts).strip()
    if not text:
        # fallback: any reasoning text
        text = "".join(p.get("text", "") for p in resp.get("parts", []) if p.get("type") == "reasoning").strip()
    return text


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self):
        auth = self.headers.get("Authorization", "")
        return auth == f"Bearer {BRIDGE_TOKEN}"

    def do_GET(self):
        if not self._authorized():
            self._send({"error": "unauthorized"}, 401)
            return
        if self.path.startswith("/v1/models"):
            self._send({"object": "list", "data": [{"id": m, "object": "model"} for m in FREE_MODELS]})
        elif self.path in ("/health", "/v1/health"):
            self._send({"ok": True})
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        if not self._authorized():
            self._send({"error": "unauthorized"}, 401)
            return
        if self.path == "/v1/chat/completions":
            n = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(n) or b"{}")
            except Exception:
                self._send({"error": {"message": "bad json"}}, 400)
                return
            model = body.get("model", "")
            messages = body.get("messages", [])
            if model not in FREE_MODELS:
                self._send({"error": {"message": f"unknown free model: {model}"}}, 400)
                return
            try:
                text = opencode_complete(model, messages)
                self._send({
                    "id": "chatcmpl-opencode-bridge",
                    "object": "chat.completion",
                    "created": 0,
                    "model": model,
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                                 "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
                })
            except Exception as e:
                self._send({"error": {"message": f"opencode error: {e}"}}, 502)
        else:
            self._send({"error": "not found"}, 404)

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    from http.server import ThreadingHTTPServer
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"opencode free bridge on http://127.0.0.1:{PORT}/v1", flush=True)
    if not os.environ.get("OPENCODE_BRIDGE_TOKEN"):
        print(f"auth token (set OPENCODE_BRIDGE_TOKEN to pin): {BRIDGE_TOKEN}", flush=True)
    srv.serve_forever()
