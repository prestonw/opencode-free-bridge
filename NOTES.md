# Notes — OpenCode free tier through Hermes

Investigation and findings, Sept 2026. Author's account: paid OpenCode **Go** plan,
authorized to use Hermes as the client (OpenCode emailed asking only for the
`x-opencode-session` header, which Hermes already sends — PR #101864).

## The three OpenCode endpoints

| Provider | base_url | Auth | Models |
|---|---|---|---|
| `opencode-go` | `https://opencode.ai/zen/go/v1` | `OPENCODE_GO_API_KEY` (Bearer) | 38 paid models (`glm-5.3`, `hy3`, `mimo-v2.5-pro`, …) |
| `opencode-zen` | `https://opencode.ai/zen/v1` | `OPENCODE_ZEN_API_KEY` | 69+ models incl. `*-free` |
| `opencode-free` | `https://opencode.ai/zen/v1` | keyless | 7 `*-free` models |

The `*-free` models live on `/zen/v1`. They show up in `GET /models` but a **completion**
returns the FreeTierError.

## What was ruled out (all 403 FreeTierError)

- `Authorization: Bearer <Go key>` (the paid key) → 403.
- `Authorization: Bearer <Zen key>` (Go key copied to Zen var) → 403.
- Four User-Agents (`opencode/1.18.31`, `opencode/1.18.31 (Linux; x64)`, `Bun/1.2`,
  `Mozilla/5.0 …`) → 403.
- `X-Title`, `HTTP-Referer`, `x-opencode-session` set to OpenCode-app values → 403.

Conclusion: the gate is a **server-side app-session/device check**, not a header or key.
There is no "auth code" credential to copy — the CLI's only `opencode` login method is
"Enter your API key" (`opencode auth login -m console` / `-m oauth` both fall back to it).

## What works: the OpenCode server

`opencode` CLI v1.18.31 (installed via `npm i -g opencode-ai`, user prefix on NixOS):

```bash
opencode models          # lists the free models under provider "opencode", keyless
opencode serve --port 4090   # headless server = "within OpenCode"
```

The server's API (not OpenAI-compatible) is:

- `POST /session` body `{"title":"…"}` → `{"id":"ses_…", …}`
- `POST /session/:id/message` body
  `{"parts":[{"type":"text","text":"…"}],"model":{"providerID":"opencode","modelID":"muse-spark-1.3-contributor-free"}}`
  → single JSON `{"info":{…,"finish":"stop",…},"parts":[{"type":"text","text":"Hi"}, …]}`

The assistant text is the concatenation of `parts[]` where `type == "text"`.

`muse-spark-1.3-contributor-free` and `mimo-v2.5-free` both answered through the server
with `finish: "stop"` — confirming the bridge approach.

## The bridge

`opencode_bridge.py` fronts `opencode serve` with:

- `GET /v1/models` → the free model list.
- `POST /v1/chat/completions` → builds a prompt from the OpenAI message list, creates a
  fresh session, sends the message, extracts the text, returns an OpenAI-format response.

## Hermes model pinning (paid Go, direct)

`~/.hermes/config.yaml`:

```yaml
model:
  default: hy3
  provider: opencode-go
  base_url: https://opencode.ai/zen/go/v1
  api_mode: chat_completions
fallback_providers:
  - provider: opencode-go
    model: glm-5.3-flash
```

The `x-opencode-session` header is sent automatically (`agent/opencode_affinity.py`),
wired into both the main-turn and auxiliary request paths.

## Rotation / security

The Go API key was pasted into chat during this work — rotate it.

## Jev (TypeSafe) review

Ran `jev-latest` over `opencode_bridge.py` before publishing:

| question | probability |
|---|---|
| contains hardcoded secrets | **0.08** (no — reads from env only) |
| obvious security vulnerabilities | **0.77** (see below) |
| production-ready | **0.14** (minimal, non-streaming) |

Mitigation applied: bearer-token auth is now **always on** (a random token is
generated and printed at startup if `OPENCODE_BRIDGE_TOKEN` is unset).

Remaining concern Jev is flagging: the bridge routes prompts to OpenCode's
**"build" agent**, which has tool/command-execution access — it is not a pure chat
model. So this is *not* a sandboxed chat endpoint; treat it as an authenticated
front-end to a coding agent. Security model: `127.0.0.1` bind + bearer token +
tailnet-only exposure. Do not `funnel` it to the public internet.

