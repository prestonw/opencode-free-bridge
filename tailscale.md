# Tailscale exposure

Each service gets its own hostname + free HTTPS cert (auto-provisioned by Tailscale)
via the **services** feature — distinct names, not port suffixes on one host.

| Hostname | Service | Backend |
|---|---|---|
| `https://bridge.tail83a10.ts.net` | `svc:bridge` | OpenCode free bridge `127.0.0.1:4059` |
| `https://sentinel.tail83a10.ts.net` | `svc:sentinel` | Sentinel dashboard `127.0.0.1:8888` |
| `https://dns.tail83a10.ts.net` | `svc:dns` | Technitium (Friday) web UI `http://10.233.2.2:5380` |

## Setup

```bash
# one service = one hostname + one auto-cert
sudo tailscale serve --bg --service=svc:bridge   --https=443 4059
sudo tailscale serve --bg --service=svc:sentinel --https=443 8888
sudo tailscale serve --bg --service=svc:dns      --https=443 http://10.233.2.2:5380

tailscale serve status   # view all services
```

`--bg` runs it in the background; the service persists across reboots as long as
`tailscaled` is up. Each `svc:NAME` becomes `NAME.tail83a10.ts.net` with its own
Tailscale-issued Let's Encrypt cert — no cert files to manage.

## Approval

A service proxy needs one-time tailnet-admin approval. Either approve it in the
Tailscale admin console (Services page), or via the admin API. Until approved, the
hostname resolves but returns 403.

## Lifecycle

```bash
sudo tailscale serve --service=svc:bridge --https=443 off   # stop proxy
sudo tailscale serve clear svc:bridge                       # remove config
```

All three are bound tailnet-only (no `funnel`), so they are reachable only from devices
on the tailnet — not the public internet.
