#!/usr/bin/env bash
# opencode-free-bridge installer
#
# Sets up, on Linux (systemd user units) or macOS (launchd/launchctl):
#   1. opencode CLI (via npm, if missing)
#   2. opencode serve on 127.0.0.1:4090   (the "within OpenCode" client)
#   3. opencode_bridge.py on 127.0.0.1:4059 (OpenAI-compatible proxy)
#   4. Hermes config: opencode-free-bridge provider + default model
#
# Usage:
#   ./install.sh              # install + start everything
#   ./install.sh --no-hermes  # skip the Hermes config step
#   ./install.sh --uninstall  # stop + remove services (keeps repo dir)
#
# Idempotent: safe to re-run; it replaces existing unit files.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SCRIPT="$REPO_DIR/opencode_bridge.py"
BRIDGE_PORT="${OPENCODE_BRIDGE_PORT:-4059}"
SERVE_PORT="${OPENCODE_SERVE_PORT:-4090}"
ROUTER_PORT="${OPENCODE_ROUTER_PORT:-4060}"
ENV_FILE="$REPO_DIR/bridge.env"
LOG_TAG="[opencode-free-bridge]"

say() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- platform
OS="$(uname -s)"
case "$OS" in
  Linux)  PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *CYGWIN*|*MINGW*) PLATFORM=windows ;;
  *) die "unsupported OS: $OS (use windows-install.ps1 on Windows)" ;;
esac

# ---------------------------------------------------------------- token
ensure_token() {
  if [[ -s "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    if [[ -n "${OPENCODE_BRIDGE_TOKEN:-}" ]]; then
      say "reusing existing bridge token from bridge.env"
      return
    fi
  fi
  local token
  if command -v python3 >/dev/null 2>&1; then
    token="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
  else
    token="$(head -c32 /dev/urandom | base64 | tr -d '/+=' | head -c32)"
  fi
  cat > "$ENV_FILE" <<EOF
OPENCODE_BRIDGE_TOKEN=$token
OPENCODE_SERVER_URL=http://127.0.0.1:$SERVE_PORT
EOF
  chmod 600 "$ENV_FILE"
  say "generated new bridge token -> $ENV_FILE"
}

# ---------------------------------------------------------------- npm / opencode
ensure_opencode() {
  # `.local/npm/bin` may not be on PATH (NixOS/macOS custom prefix), include it.
  if [[ -x "$HOME/.local/npm/bin/opencode" ]] && ! command -v opencode >/dev/null 2>&1; then
    export PATH="$HOME/.local/npm/bin:$PATH"
  fi
  if ! command -v opencode >/dev/null 2>&1; then
    say "installing opencode-ai via npm"
    # Global npm prefix may be read-only (NixOS); use a user prefix fallback.
    if ! npm i -g opencode-ai 2>/dev/null; then
      npm config set prefix "$HOME/.local/npm"
      export PATH="$HOME/.local/npm/bin:$PATH"
      npm i -g opencode-ai
    fi
    # Re-check after install, including the user-prefix location.
    if ! command -v opencode >/dev/null 2>&1 && [[ -x "$HOME/.local/npm/bin/opencode" ]]; then
      export PATH="$HOME/.local/npm/bin:$PATH"
    fi
  fi
  command -v opencode >/dev/null 2>&1 || die "opencode not found on PATH after npm install (searched: \$PATH, \$HOME/.local/npm/bin)"
  say "opencode CLI: $(command -v opencode)"
  # make sure the systemd/launchd unit can find it too
  export OPENCODE_BIN="$(command -v opencode)"
}

# ---------------------------------------------------------------- service mgmt
UNAME="$(id -un)"

write_env_hint() {
  cat "$ENV_FILE" >&2
}

install_linux() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir" "$REPO_DIR/logs"

  # Stop anything already bound to our ports: first the managed units, then stragglers.
  systemctl --user disable --now opencode-bridge.service opencode-serve.service 2>/dev/null || true
  systemctl --user reset-failed opencode-bridge.service opencode-serve.service 2>/dev/null || true
  for p in "$SERVE_PORT" "$BRIDGE_PORT"; do
    if python3 - "$p" <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1]))); s.close(); sys.exit(0)
except Exception:
    sys.exit(1)
PY
    then
      say "port $p already in use — killing the process holding it"
      local killer
      killer="$(python3 - "$p" <<'PY'
import subprocess, sys, re
out = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True).stdout
for line in out.splitlines():
    if re.search(rf"127\.0\.0\.1:{sys.argv[1]}\s", line):
        m = re.search(r"pid=(\d+)", line)
        if m:
            print(m.group(1))
            break
PY
)"
      [[ -n "$killer" ]] && { kill "$killer" 2>/dev/null || sudo kill "$killer" 2>/dev/null || true; sleep 1; }
    fi
  done

  ensure_opencode
  ensure_token
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  # The free tier must run KEYLESS: any auth.json (paid Go/zen key) in the data
  # dir makes the client route free-model requests through Console's per-workspace
  # quota accounting, which rate-limits and the client retries silently (looks like
  # a hang). A dedicated keyless XDG_DATA_HOME avoids that entirely.
  if [[ ! -f "$REPO_DIR/data/.config_ready" ]]; then
    mkdir -p "$REPO_DIR/data"
    touch "$REPO_DIR/data/.config_ready"
  fi
  [[ ! -f "$REPO_DIR/data/auth.json" ]] || { say "ERROR: $REPO_DIR/data/auth.json must not exist (free tier must be keyless)"; die "remove $REPO_DIR/data/auth.json"; }

  local serve_bin
  serve_bin="$(command -v opencode)"

  cat > "$unit_dir/opencode-serve.service" <<EOF
[Unit]
Description=OpenCode headless server (free-tier backend)
After=network-online.target

[Service]
ExecStart=$serve_bin serve --port $SERVE_PORT --hostname 127.0.0.1
Restart=on-failure
RestartSec=3
Environment=PATH=$HOME/.local/npm/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
Environment=XDG_DATA_HOME=$REPO_DIR/data/opencode-share
Environment=XDG_CONFIG_HOME=$REPO_DIR/data/opencode-config
WorkingDirectory=$REPO_DIR
StandardOutput=append:$REPO_DIR/logs/opencode-serve.log
StandardError=append:$REPO_DIR/logs/opencode-serve.log

[Install]
WantedBy=default.target
EOF

  local py_bin
  py_bin="$(command -v python3)"

  cat > "$unit_dir/opencode-bridge.service" <<EOF
[Unit]
Description=OpenCode free bridge (OpenAI-compatible proxy, port $BRIDGE_PORT)
After=opencode-serve.service
Requires=opencode-serve.service

[Service]
ExecStart=/bin/sh -c 'set -a; [ -f $ENV_FILE ] && . $ENV_FILE; set +a; exec $py_bin $BRIDGE_SCRIPT'
Restart=on-failure
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=HOME=$HOME
WorkingDirectory=$REPO_DIR
StandardOutput=append:$REPO_DIR/logs/opencode-bridge.log
StandardError=append:$REPO_DIR/logs/opencode-bridge.log

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now opencode-serve.service opencode-bridge.service

  # Linger so services survive logout/reboot
  loginctl show-user "$UNAME" --property=Linger >/dev/null 2>&1 || true
  if ! loginctl show-user "$UNAME" --property=Linger 2>/dev/null | grep -q '^Linger=yes'; then
    say "attempting: sudo loginctl enable-linger $UNAME  (so services start at boot)"
    sudo loginctl enable-linger "$UNAME" 2>/dev/null \
      || say "WARNING: could not enable linger; services stop at logout until you run the sudo command above"
  fi
}

install_macos() {
  local plist_dir="$HOME/Library/LaunchAgents"
  mkdir -p "$plist_dir" "$REPO_DIR/logs"

  ensure_opencode
  ensure_token
  # shellcheck disable=SC1090
  source "$ENV_FILE"

  local serve_bin py_bin
  serve_bin="$(command -v opencode)"
  py_bin="$(command -v python3)"

  cat > "$plist_dir/com.opencode.serve.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.opencode.serve</string>
  <key>ProgramArguments</key>
  <array>
    <string>$serve_bin</string><string>serve</string>
    <string>--port</string><string>$SERVE_PORT</string>
    <string>--hostname</string><string>127.0.0.1</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>XDG_DATA_HOME</key><string>$REPO_DIR/data/opencode-share</string>
    <key>XDG_CONFIG_HOME</key><string>$REPO_DIR/data/opencode-config</string>
  </dict>
  <key>StandardOutPath</key><string>$REPO_DIR/logs/opencode-serve.log</string>
  <key>StandardErrorPath</key><string>$REPO_DIR/logs/opencode-serve.log</string>
</dict>
</plist>
EOF

  cat > "$plist_dir/com.opencode.bridge.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.opencode.bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>$py_bin</string><string>$BRIDGE_SCRIPT</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPENCODE_BRIDGE_TOKEN</key><string>$OPENCODE_BRIDGE_TOKEN</string>
    <key>OPENCODE_SERVER_URL</key><string>http://127.0.0.1:$SERVE_PORT</string>
    <key>OPENCODE_BRIDGE_PORT</key><string>$BRIDGE_PORT</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$REPO_DIR/logs/opencode-bridge.log</string>
  <key>StandardErrorPath</key><string>$REPO_DIR/logs/opencode-bridge.log</string>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/com.opencode.serve" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/com.opencode.bridge" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist_dir/com.opencode.serve.plist"
  launchctl bootstrap "gui/$(id -u)" "$plist_dir/com.opencode.bridge.plist"
  launchctl enable "gui/$(id -u)/com.opencode.serve"
  launchctl enable "gui/$(id -u)/com.opencode.bridge"
}

# ---------------------------------------------------------------- wait for ports
wait_port() {
  local port="$1" tries=30
  for _ in $(seq 1 "$tries"); do
    if python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
    s.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
    then
      return 0
    fi
    sleep 1
  done
  return 1
}

verify() {
  say "waiting for opencode serve on :$SERVE_PORT ..."
  wait_port "$SERVE_PORT" || die "opencode serve did not come up — check $REPO_DIR/logs/opencode-serve.log"
  say "waiting for bridge on :$BRIDGE_PORT ..."
  wait_port "$BRIDGE_PORT" || die "opencode bridge did not come up — check $REPO_DIR/logs/opencode-bridge.log"
  sleep 1  # give the bridge a second to fetch the model list

  local token
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  token="${OPENCODE_BRIDGE_TOKEN:?no token in $ENV_FILE}"

  local models_json models
  models_json="$(python3 - "$token" "$BRIDGE_PORT" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(
    f"http://127.0.0.1:{sys.argv[2]}/v1/models",
    headers={"Authorization": f"Bearer {sys.argv[1]}"},
)
try:
    d = json.loads(urllib.request.urlopen(req, timeout=15).read())
    print(",".join(m["id"] for m in d["data"]))
except Exception as e:
    sys.exit(f"model list failed: {e}")
PY
)" || die "bridge /v1/models failed"

  # Pick the fastest-feeling default: prefer muse-spark-1.3-contributor-free.
  local default_model=""
  for m in muse-spark-1.3-contributor-free mimo-v2.5-free ling-3.0-flash-fin-free; do
    if [[ ",$models_json," == *",$m,"* ]]; then default_model="$m"; break; fi
  done
  [[ -n "$default_model" ]] || default_model="${models_json%%,*}"

  say "models: $(echo "$models_json" | tr ',' ' ')"
  echo "$default_model" > "$REPO_DIR/.default_model"

  # --- live test call
  say "test completion (may take ~10–30s) ..."
  local curl_out
  curl_out="$(curl -s -m 120 http://127.0.0.1:"$BRIDGE_PORT"/v1/chat/completions \
    -H "Authorization: Bearer ${OPENCODE_BRIDGE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$default_model\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}]}")"
  echo "$curl_out" | grep -q '"finish_reason":[[:space:]]*"stop"' \
    || die "test completion failed: $curl_out"
  say "test completion OK: $(echo "$curl_out" | head -c200)"
}

# ---------------------------------------------------------------- hermes config
install_hermes() {
  command -v hermes >/dev/null 2>&1 || { say "hermes not found — skipping Hermes config"; return; }

  local token default_model
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  token="${OPENCODE_BRIDGE_TOKEN:?no token in $ENV_FILE}"
  default_model="$(cat "$REPO_DIR/.default_model" 2>/dev/null || echo muse-spark-1.3-contributor-free)"

  say "configuring Hermes: provider opencode-free-bridge -> 127.0.0.1:$BRIDGE_PORT"
  hermes config set providers.opencode-free-bridge.base_url "http://127.0.0.1:$BRIDGE_PORT/v1"
  hermes config set providers.opencode-free-bridge.key_env "OPENCODE_BRIDGE_TOKEN"
  hermes config set providers.opencode-free-bridge.api_mode "chat_completions"
  hermes config set providers.opencode-free-bridge.default_model "$default_model"

  # Store the token in Hermes .env (never config.yaml)
  local hermes_env="${HERMES_HOME:-$HOME/.hermes}/.env"
  touch "$hermes_env"; chmod 600 "$hermes_env"
  if grep -q '^OPENCODE_BRIDGE_TOKEN=' "$hermes_env"; then
    sed -i.bak "s|^OPENCODE_BRIDGE_TOKEN=.*|OPENCODE_BRIDGE_TOKEN=$token|" "$hermes_env"
  else
    printf '\nOPENCODE_BRIDGE_TOKEN=%s\n' "$token" >> "$hermes_env"
  fi
  say "token written to $hermes_env as OPENCODE_BRIDGE_TOKEN"

  if [[ "${1:-}" != "--no-default-switch" ]]; then
    hermes config set model.default "$default_model"
    hermes config set model.provider "opencode-free-bridge"
    hermes config set model.base_url "http://127.0.0.1:$BRIDGE_PORT/v1"
    hermes config set model.api_mode "chat_completions"
    say "Hermes default model -> $default_model (opencode-free-bridge)"
  fi
  # Always register the paid-pool provider too (harmless if accounts aren't set up yet)
  hermes config set providers.opencode-paid-router.base_url "http://127.0.0.1:$ROUTER_PORT/v1"
  hermes config set providers.opencode-paid-router.key_env "OPENCODE_BRIDGE_TOKEN"
  hermes config set providers.opencode-paid-router.api_mode "chat_completions"
  hermes config set providers.opencode-paid-router.default_model "glm-5.3-flash"
  say "Hermes provider opencode-paid-router registered -> 127.0.0.1:$ROUTER_PORT (glm-5.3-flash)"
}

# ---------------------------------------------------------------- uninstall
cleanup_stale() {
  # UPGRADE CLEANUP: remove stale service units/agents left by previous versions.
  local py
  py="$(command -v python3)"
  # All opencode-* units this installer used to manage (any version)
  local stale
  stale="$(systemctl --user list-unit-files --type=service --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '^opencode-(serve|bridge|paid-router)' || true)"
  if [[ -n "$stale" ]]; then
    systemctl --user stop $stale 2>/dev/null || true
    for u in $stale; do
      systemctl --user disable "$u" 2>/dev/null || true
      rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$u"
    done
    systemctl --user daemon-reload || true
    systemctl --user reset-failed 2>/dev/null || true
    say "upgrade cleanup: removed stale units: $(echo "$stale" | tr '\n' ' ')"
  fi
}

uninstall() {
  cleanup_stale
  systemctl --user disable --now opencode-bridge.service opencode-serve.service 2>/dev/null || true
  systemctl --user disable --now opencode-paid-router.service opencode-serve-*.service 2>/dev/null || \
    bash -c 'systemctl --user list-unit-files | grep -E "^opencode-(paid-router|serve-)" | awk "{print \$1}" | xargs -r systemctl --user disable --now' 2>/dev/null || true
  rm -f "${XDG_CONFIG_HOME:-$HOME/.config}"/systemd/user/opencode-{bridge,serve,paid-router}.service \
        "${XDG_CONFIG_HOME:-$HOME/.config}"/systemd/user/opencode-serve-*.service
  systemctl --user daemon-reload || true
  say "systemd units removed"
  if [[ -d "$HOME/Library/LaunchAgents" ]]; then
    for lbl in com.opencode.serve com.opencode.bridge com.opencode.paid-router; do
      launchctl bootout "gui/$(id -u)/$lbl" 2>/dev/null || true
      rm -f "$HOME/Library/LaunchAgents/$lbl.plist"
    done
    # per-account agents
    for f in "$HOME/Library/LaunchAgents"/com.opencode.serve-acc*.plist; do
      [[ -e "$f" ]] || continue
      launchctl bootout "gui/$(id -u)/$(basename "$f" .plist)" 2>/dev/null || true
      rm -f "$f"
    done
    say "launchd agents removed"
  fi
  say "uninstalled (Hermes config untouched — remove manually if wanted)"
}

upgrade_cleanup() {
  case "$PLATFORM" in
    linux)  cleanup_stale ;;
    macos)
      # remove per-account agents before re-adding (macOS)
      for f in "$HOME/Library/LaunchAgents"/com.opencode.serve-acc*.plist; do
        [[ -e "$f" ]] || continue
        launchctl bootout "gui/$(id -u)/$(basename "$f" .plist)" 2>/dev/null || true
        rm -f "$f"
      done
      ;;
  esac
}

# ---------------------------------------------------------------- main
case "${1:-install}" in
  install)
    upgrade_cleanup || true
    case "$PLATFORM" in linux) install_linux ;; macos) install_macos ;; esac
    verify
    install_hermes "${2:-}"
    say "done. bridge: http://127.0.0.1:$BRIDGE_PORT/v1 (token in $ENV_FILE)"
    say "hermes alias: /model opencode-free-bridge/$(cat "$REPO_DIR/.default_model" 2>/dev/null || echo muse-spark-1.3-contributor-free)"
    if compgen -G "$REPO_DIR/accounts/*/auth.json" > /dev/null; then
      say "paid accounts detected -> running manage-accounts.sh upgrade"
      "$REPO_DIR/manage-accounts.sh" upgrade || say "WARNING: paid pool upgrade failed (see manage-accounts.sh output)"
    else
      say "no paid accounts registered (optional: $0/manage-accounts.sh add <auth.json>)"
    fi
    ;;
  --paid)
    "$REPO_DIR/manage-accounts.sh" upgrade
    ;;
  uninstall)
    uninstall
    "$REPO_DIR/manage-accounts.sh" remove all 2>/dev/null || true
    ;;
  --uninstall)
    uninstall
    "$REPO_DIR/manage-accounts.sh" remove all 2>/dev/null || true
    ;;
  *)
    die "usage: $0 [install | --paid | --uninstall]"
    ;;
esac
