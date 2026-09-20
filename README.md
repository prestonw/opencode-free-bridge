# OpenCode Free Bridge

Route OpenCode's keyless **free** models (`ling-3.0-flash-fin-free`,
`muse-spark-1.3-contributor-free`, `mimo-v2.5-free`, `nemotron-*`, etc.) through any
OpenAI-compatible client — Hermes, or anything else that speaks `/v1/chat/completions`.

Works on **Linux (systemd user units)** and **macOS (launchd)**.

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
Hermes / any client ──POST /v1/chat/completions──▶  opencode_bridge.py  ──▶  opencode serve  ──▶  opencode.ai (free tier)
                                                  (this repo, :4059)        (:4090)
```

The bridge is stateless: it creates a fresh `opencode` session per request, folds the
full message history into the prompt, and extracts the assistant text from the response.

## Install (Linux + macOS)

```bash
git clone https://github.com/prestonw/opencode-free-bridge
cd opencode-free-bridge
./install.sh
```

What it does:

1. Installs `opencode-ai` via npm if missing (handles NixOS read-only global prefix).
2. Generates a bearer token in `bridge.env` (chmod 600, reused on re-runs).
3. Writes and starts the services:
   - Linux: `~/.config/systemd/user/opencode-serve.service` + `opencode-bridge.service`
   - macOS: `~/Library/LaunchAgents/com.opencode.serve.plist` + `com.opencode.bridge.plist`
4. Frees the ports first (kills stragglers holding 4090/4059).
5. Verifies: waits for ports, fetches `/v1/models` for real, runs a live test completion
   through the full stack.
6. Configures Hermes: adds the `opencode-free-bridge` provider, stores the token in
   `~/.hermes/.env` (never in config.yaml), and sets the default model.

Options:

```bash
./install.sh --no-default-switch   # add provider, don't change the Hermes default model
./install.sh --uninstall           # stop + remove services (Hermes config left alone)
```

Logs go to `./logs/opencode-serve.log` and `./logs/opencode-bridge.log`.

### Manual (no services)

```bash
npm i -g opencode-ai                    # NixOS: npm config set prefix ~/.local/npm first
opencode serve --port 4090 --hostname 127.0.0.1 &
OPENCODE_BRIDGE_TOKEN=mytoken python3 opencode_bridge.py
```

## Config

| Env var | Default | Purpose |
|---|---|---|
| `OPENCODE_SERVER_URL` | `http://127.0.0.1:4090` | opencode serve endpoint |
| `OPENCODE_BRIDGE_PORT` | `4059` | bridge listen port |
| `OPENCODE_BRIDGE_TOKEN` | random (printed) | Bearer token required by clients |
| `OPENCODE_TIMEOUT` | `300` | upstream completions timeout (s) |
| `OPENCODE_MODEL_REFRESH` | `3600` | re-fetch the model list every N s (0 = off) |

## API

```bash
curl http://127.0.0.1:4059/v1/models -H "Authorization: Bearer $OPENCODE_BRIDGE_TOKEN"
curl http://127.0.0.1:4059/v1/chat/completions \
  -H "Authorization: Bearer $OPENCODE_BRIDGE_TOKEN" -H 'Content-Type: application/json' \
  -d '{"model":"muse-spark-1.3-contributor-free","messages":[{"role":"user","content":"hi"}]}'
```

- `GET /v1/models` — live list (fetched from opencode's config, falling back to a
  built-in list if unavailable).
- `POST /v1/chat/completions` — blocking or SSE streaming (`"stream": true`; the
  stream is single-chunk: full text, then finish, then `[DONE]`).
- `GET /health` — bridge liveness + model count.

Unknown models are rejected with the list of available free models in the error body.

## Hermes

```yaml
providers:
  opencode-free-bridge:
    base_url: http://127.0.0.1:4059/v1
    key_env: OPENCODE_BRIDGE_TOKEN
    api_mode: chat_completions
    default_model: muse-spark-1.3-contributor-free
```

`install.sh` sets this up; per-session switch: `/model opencode-free-bridge/<model>`.

## Troubleshooting

- **Requests hang / empty responses.** Check opencode's own log first:
  `tail ~/.local/share/opencode/log/opencode.log` (or
  `$XDG_DATA_HOME/opencode/log/opencode.log` for the service instance). The known
  causes, in order of likelihood:
  1. **A paid key (`auth.json`) is present in the server's data dir.** Free-model
     requests then go through Console's per-workspace quota accounting, the server
     gets rate-limited, and the client silently retries with backoff — which looks
     exactly like a hang. The installer isolates the service with its own
     `XDG_DATA_HOME`/`XDG_CONFIG_HOME` under `data/` and refuses to run if a key
     exists there. Keep paid keys in your normal user opencode install, separate
     from the free-tier server.
  2. **Upstream throttling** — test with a paid model through the same CLI:
     `opencode run -m opencode-go/<your-go-model> 'Reply ok'`. If the paid model is
     fast while free models stall, it's upstream, not the bridge.
- **`{"error":"unauthorized"}`** — client token doesn't match `bridge.env` / Hermes
  `.env`. Same token must be in both.
- **systemd: `systemctl --user status opencode-serve opencode-bridge`** and the
  `logs/` files.
- **Port conflicts.** The installer cleans 4090/4059; for manual runs make sure no old
  `opencode serve`/bridge is still bound.

## Paid multi-account router (optional)

`manage-accounts.sh` runs N isolated **paid** OpenCode instances — one per account
(`auth.json` Go or Zen key) — each on its own serve port, and load-balances them
behind one router endpoint. Each profile is a genuinely distinct account (own
key, own workspace, own on-disk state); the router just spreads requests evenly
across them and fails over when one errors.

```bash
./manage-accounts.sh add <auth.json>   # register an account profile
./manage-accounts.sh list
./manage-accounts.sh upgrade           # write + start services, verify
./manage-accounts.sh stop|start|restart
./manage-accounts.sh remove <index|all>
```

The pool listens on port **4060** with the same `/v1` surface: `/v1/models` is the
union across accounts, `POST /v1/chat/completions` round-robins (with per-account
failover), and `/health` reports `accounts_up`. Point any OpenAI client at
`http://127.0.0.1:4060/v1` with the same bridge token.

Note: accounts must be different real accounts (separate subscriptions). The
router does not attempt to mask or correlate away client identity — each profile
authenticates exactly as its own OpenCode account.

## Tailscale exposure

Each service can get its own hostname + free HTTPS cert via Tailscale services — see
[`tailscale.md`](tailscale.md).

## Limitations

- **Non-incremental streaming** — SSE is real but arrives as one chunk.
- **Fresh session per request** — no server-side memory; full history re-sent each turn.
- The `opencode serve` default is the "build" agent; responses carry build-agent framing
  but are plain assistant text for chat prompts.
- Bound to `127.0.0.1` — do not expose beyond localhost without ALSO keeping the
  bridge token private (`OPENCODE_SERVER_PASSWORD` protects the serve endpoint only).
