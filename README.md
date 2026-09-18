# OpenCode Free Bridge

Route OpenCode's keyless **free** models (`ling-3.0-flash-fin-free`,
`muse-spark-1.3-contributor-free`, `mimo-v2.5-free`, `nemotron-*`, etc.) through any
OpenAI-compatible client — Hermes, or anything else that speaks `/v1/chat/completions`.

## Why this exists

OpenCode's free tier returns, on **direct** API calls:

```
403 FreeTierError: "OpenCode's free tier can only be used from within OpenCode"
```

The gate is a server-side app-session check, not a header or API key. Sending the Go API
key as `Bearer`, any `User-Agent` (including the CLI's own), `X-Title`, or
`x-opencode-session` all still 403. See `NOTES.md` for the full investigation.

But the OpenCode CLI *is* "within OpenCode". Its headless server (`opencode serve`) can
use the free models natively. This bridge fronts that server with an OpenAI-compatible
HTTP API so Hermes (or any client) can use them too.

## Architecture

```
Hermes  ──POST /v1/chat/completions──▶  opencode_bridge.py  ──▶  opencode serve  ──▶  opencode.ai (free tier)
  127.0.0.1:4059                        (this repo)              127.0.0.1:4090
```

The bridge is stateless: it creates a fresh `opencode` session per request, folds the
full message history into the prompt, and extracts the assistant text from the response.

## Setup

### 1. Install the OpenCode CLI

```bash
npm i -g opencode-ai
# NixOS: the global npm prefix is read-only, so:
npm config set prefix "$HOME/.local/npm"
npm i -g opencode-ai
export PATH="$HOME/.local/npm/bin:$PATH"
```

### 2. Start the OpenCode server (the "within OpenCode" client)

```bash
opencode serve --port 4090 --hostname 127.0.0.1
# listening on http://127.0.0.1:4090
```

No API key needed for the free tier. (For paid Go models use the API key via
`opencode auth login` or `OPENCODE_GO_API_KEY`.)

### 3. Start the bridge

```bash
python3 opencode_bridge.py
# opencode free bridge on http://127.0.0.1:4059/v1
```

Config via env: `OPENCODE_SERVER_URL` (default `http://127.0.0.1:4090`),
`OPENCODE_BRIDGE_PORT` (default `4059`).

### 4. Test

```bash
curl http://127.0.0.1:4059/v1/models
curl -X POST http://127.0.0.1:4059/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}]}'
```

### 5. Point Hermes at it

Add a custom OpenAI-compatible provider with `base_url: http://127.0.0.1:4059/v1` and the
free models. (The bridge ignores the `Authorization` header, so any placeholder key works.)

## Models served

`ling-3.0-flash-fin-free`, `mimo-v2.5-free`, `muse-spark-1.2-contributor-free`,
`muse-spark-1.3-contributor-free`, `nemotron-3-ultra-free`, `nemotron-3.5-lightning-free`,
`big-pickle`.

## Limitations

- **Non-streaming.** The bridge returns a complete response, not an SSE stream.
- **Fresh session per request.** No server-side conversation memory; the full history is
  re-sent each turn.
- The `opencode serve` default is the "build" agent, so responses carry the build agent's
  framing (and the server may report watched file changes). Responses are still plain
  assistant text for chat-style prompts.
- Bound to `127.0.0.1` by default — do not expose it beyond localhost (the OpenCode
  server is unsecured unless `OPENCODE_SERVER_PASSWORD` is set).
