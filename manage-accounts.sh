#!/usr/bin/env bash
# manage-accounts.sh — set up and run multiple PAID opencode accounts, each in its
# own isolated data dir, each as its own systemd user service (or launchd agent),
# each behind its own serve port. One paid router process load-balances across them.
#
# IMPORTANT: this does NOT defeat any client detection. Each profile IS a distinct
# OpenCode account (distinct key, workspace, and on-disk state) — exactly what the
# server would see from N legitimate subscriptions on one machine.
#
# Usage:
#   ./manage-accounts.sh add <auth.json file>      register an account profile
#   ./manage-accounts.sh list                      show profiles
#   ./manage-accounts.sh upgrade                   write + start services for all
#                                                  registered profiles + the router
#   ./manage-accounts.sh stop|start|restart        manage all profile services
#   ./manage-accounts.sh remove <index|all>        delete a profile's data + services
#
# Profile layout under REPO_DIR/accounts/:
#   <N>/auth.json        the account's key(s) (you supply; NOT committed)
#   <N>/xdg-share/       its opencode.db, logs, sessions
#   <N>/xdg-config/      its opencode config
# Services:
#   opencode-serve-<N>.service  port 4090+N  (Linux)
#   opencode-paid-router.service  port 4060 (Linux)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACC_DIR="$REPO_DIR/accounts"
ENV_FILE="$REPO_DIR/bridge.env"
UNAME="$(id -un)"
ROUTER_PORT="${OPENCODE_ROUTER_PORT:-4060}"
LOG_TAG="[opencode-accounts]"
say() { printf '%s %s\n' "$LOG_TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$LOG_TAG" "$*" >&2; exit 1; }

OS="$(uname -s)"
case "$OS" in Linux) PLATFORM=linux;; Darwin) PLATFORM=macos;; *) die "unsupported OS";; esac

ensure_opencode() {
  if [[ -x "$HOME/.local/npm/bin/opencode" ]]; then export PATH="$HOME/.local/npm/bin:$PATH"; fi
  command -v opencode >/dev/null 2>&1 || die "opencode CLI not found (install first)"
}

next_index() {
  # First free index 1..99 based on existing dirs
  for i in $(seq 1 99); do
    [[ -d "$ACC_DIR/$i" ]] || { echo "$i"; return; }
  done
  die "no free profile slots"
}

zone_wait_port() {
  local port="$1" tries=30
  for _ in $(seq 1 $tries); do
    python3 -c "import socket,sys;s=socket.socket();s.settimeout(1)
try:
    s.connect(('127.0.0.1',int('$1')));sys.exit(0)
except Exception:
    sys.exit(1)" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

cmd_add() {
  local src="${1:?usage: manage-accounts.sh add <auth.json file>}"
  [[ -f "$src" ]] || die "no such file: $src"
  python3 -c "import json,sys;json.load(open('$src'))" || die "not valid JSON: $src"
  python3 - "$src" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not isinstance(d, dict) or not d:
    sys.exit("auth.json has no providers inside")
# tolerate single-provider format
if "type" in d:
    k = sys.argv[2]
    sys.exit("wrap the single provider in a dict like {\"opencode-go\": ...}")
for k, v in d.items():
    if not isinstance(v, dict) or "key" not in v:
        sys.exit(f"provider '{k}' in auth.json lacks a 'key'")
print("keys:", ", ".join(d.keys()))
PY
  local idx
  idx="$(next_index)"
  local dir="$ACC_DIR/$idx"
  mkdir -p "$dir/xdg-share/opencode" "$dir/xdg-config/opencode"
  cp "$src" "$dir/auth.json"
  chmod 600 "$dir/auth.json"
  # Minimal config: give this profile its own opencode config (no API keys in config!)
  cat > "$dir/xdg-config/opencode/opencode.jsonc" <<'EOF'
{
  // per-account opencode config; keys live in auth.json, not here
}
EOF
  say "added account profile $idx at $dir"
  say "now run: $0 upgrade"
}

cmd_list() {
  if ! compgen -G "$ACC_DIR/*" > /dev/null; then echo "no profiles"; return 0; fi
  for d in "$ACC_DIR"/*/; do
    local idx; idx="$(basename "$d")"
    [[ -f "$d/auth.json" ]] || continue
    local who
    who="$(python3 -c "import json;print(', '.join(json.load(open('$d/auth.json')).keys()))" 2>/dev/null || echo '?')"
    say "profile $idx  providers: $who  data=$d"
  done
}

install_linux_all() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir" "$REPO_DIR/logs"
  ensure_opencode
  local serve_bin py_bin ports=()
  serve_bin="$(command -v opencode)"
  py_bin="$(command -v python3)"

  # stop old router first (it references stale ports)
  systemctl --user disable --now opencode-paid-router.service 2>/dev/null || true

  local idx=0
  for d in "$ACC_DIR"/*/; do
    [[ -f "$d/auth.json" ]] || continue
    idx=$((idx+1))
    local port=$((4090 + idx))   # 4091, 4092, ... (4090 is the free-tier serve)
    # safety: never collide with the free-tier port
    [[ "$port" == "${SERVE_PORT:-4090}" ]] && port=$((port+1))
    ports+=("$port")

    # Stop an existing unit for this index before rewriting it
    systemctl --user disable --now "opencode-serve-$idx.service" 2>/dev/null || true
    # Free the port if a straggler holds it
    if python3 -c "import socket;s=socket.socket();s.settimeout(1)
try:
    s.connect(('127.0.0.1','$port'));s.close();exit(0)
except Exception:
    exit(1)" 2>/dev/null; then
      local kill_pid
      kill_pid="$(python3 -c "
import subprocess, re
out = subprocess.run(['ss','-tlnp'], capture_output=True, text=True).stdout
for line in out.splitlines():
    if re.search(rf'127\\.0\\.0\\.1:$port\\s', line):
        m = re.search(r'pid=(\\d+)', line)
        if m: print(m.group(1)); break" 2>/dev/null)"
      [[ -n "$kill_pid" ]] && kill "$kill_pid" 2>/dev/null || true
      sleep 1
    fi

    cat > "$unit_dir/opencode-serve-$idx.service" <<EOF
[Unit]
Description=OpenCode serve (paid account $idx)
After=network-online.target

[Service]
ExecStart=$serve_bin serve --port $port --hostname 127.0.0.1
Restart=on-failure
RestartSec=3
Environment=PATH=$HOME/.local/npm/bin:/usr/local/bin:/usr/bin:/bin
Environment=HOME=$HOME
Environment=XDG_DATA_HOME=$d/xdg-share
Environment=XDG_CONFIG_HOME=$d/xdg-config
WorkingDirectory=$REPO_DIR
StandardOutput=append:$REPO_DIR/logs/serve-$idx.log
StandardError=append:$REPO_DIR/logs/serve-$idx.log

[Install]
WantedBy=default.target
EOF
    # auth.json must live in XDG_DATA_HOME/opencode/auth.json for opencode to read it
    cp "$d/auth.json" "$d/xdg-share/opencode/auth.json"
    chmod 600 "$d/xdg-share/opencode/auth.json"
  done

  [[ $idx -gt 0 ]] || die "no account profiles registered (use: $0 add <auth.json>)"

  local port_list
  port_list="$(IFS=,; echo "${ports[*]}")"
  cat > "$unit_dir/opencode-paid-router.service" <<EOF
[Unit]
Description=OpenCode paid router (round-robin across $idx accounts, port $ROUTER_PORT)
After=network-online.target

[Service]
ExecStart=/bin/sh -c 'set -a; [ -f $ENV_FILE ] && . $ENV_FILE; set +a; exec $py_bin $REPO_DIR/opencode_paid_router.py'
Restart=on-failure
RestartSec=3
Environment=PYTHONUNBUFFERED=1
Environment=HOME=$HOME
Environment=OPENCODE_SERVE_PORTS=$port_list
Environment=OPENCODE_BRIDGE_PORT=$ROUTER_PORT
Environment=OPENCODE_PROVIDER=opencode-go
WorkingDirectory=$REPO_DIR
StandardOutput=append:$REPO_DIR/logs/paid-router.log
StandardError=append:$REPO_DIR/logs/paid-router.log

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  local units=()
  for j in $(seq 1 $idx); do units+=("opencode-serve-$j.service"); done
  units+=("opencode-paid-router.service")
  systemctl --user enable --now "${units[@]}"

  # Linger
  if ! loginctl show-user "$UNAME" --property=Linger 2>/dev/null | grep -q '^Linger=yes'; then
    sudo loginctl enable-linger "$UNAME" 2>/dev/null || say "WARN: linger not enabled"
  fi

  say "started $idx account servers + router. ports: $port_list -> $ROUTER_PORT"
}

stop_all_linux() {
  systemctl --user disable --now 'opencode-paid-router.service' 2>/dev/null || true
  local glob
  for u in $(systemctl --user list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^opencode-serve-' || true); do
    systemctl --user disable --now "$u" 2>/dev/null || true
  done
  say "services stopped"
}

start_all_linux() {
  for u in $(systemctl --user list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep '^opencode-serve-' || true); do
    systemctl --user start "$u"
  done
  systemctl --user start opencode-paid-router.service 2>/dev/null || true
  say "services started"
}

# ---- macOS (launchd) ----------------------------------------------------------
install_macos_all() {
  local plist_dir="$HOME/Library/LaunchAgents"
  mkdir -p "$plist_dir" "$REPO_DIR/logs"
  ensure_opencode

  # need the router token
  # shellcheck disable=SC1090
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  OPENCODE_BRIDGE_TOKEN="${OPENCODE_BRIDGE_TOKEN:-}"
  if [[ -z "$OPENCODE_BRIDGE_TOKEN" ]]; then
    OPENCODE_BRIDGE_TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
    { grep -v '^OPENCODE_BRIDGE_TOKEN=' "$ENV_FILE" 2>/dev/null || true;
      echo "OPENCODE_BRIDGE_TOKEN=$OPENCODE_BRIDGE_TOKEN"; } > "$ENV_FILE.new" && mv "$ENV_FILE.new" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi

  local serve_bin py_bin
  serve_bin="$(command -v opencode)"
  py_bin="$(command -v python3)"

  # out with the old
  for lbl in OpencodePaidRouter OpencodeServeAcc; do
    for f in "$plist_dir"/com.opencode.*.plist; do
      [[ -e "$f" ]] || continue
      launchctl bootout "gui/$(id -u)/$(basename "$f" .plist)" 2>/dev/null || true
      rm -f "$f"
    done
  done

  local idx=0 ports=()
  for d in "$ACC_DIR"/*/; do
    [[ -f "$d/auth.json" ]] || continue
    idx=$((idx+1))
    local port=$((4090 + idx))
    [[ "$port" == "${SERVE_PORT:-4090}" ]] && port=$((port+1))
    ports+=("$port")
    mkdir -p "$d/xdg-share/opencode" "$d/xdg-config/opencode"
    cp "$d/auth.json" "$d/xdg-share/opencode/auth.json"
    chmod 600 "$d/xdg-share/opencode/auth.json"

    cat > "$plist_dir/com.opencode.serve-acc$idx.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.opencode.serve-acc$idx</string>
  <key>ProgramArguments</key>
  <array>
    <string>$serve_bin</string><string>serve</string>
    <string>--port</string><string>$port</string>
    <string>--hostname</string><string>127.0.0.1</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>XDG_DATA_HOME</key><string>$d/xdg-share</string>
    <key>XDG_CONFIG_HOME</key><string>$d/xdg-config</string>
  </dict>
  <key>StandardOutPath</key><string>$REPO_DIR/logs/serve-$idx.log</string>
  <key>StandardErrorPath</key><string>$REPO_DIR/logs/serve-$idx.log</string>
</dict>
</plist>
EOF
    launchctl bootstrap "gui/$(id -u)" "$plist_dir/com.opencode.serve-acc$idx.plist"
  done

  [[ $idx -gt 0 ]] || die "no account profiles registered (use: $0 add <auth.json>)"

  cat > "$plist_dir/com.opencode.paid-router.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.opencode.paid-router</string>
  <key>ProgramArguments</key>
  <array>
    <string>$py_bin</string><string>$REPO_DIR/opencode_paid_router.py</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OPENCODE_SERVE_PORTS</key><string>$(IFS=,; echo "${ports[*]}")</string>
    <key>OPENCODE_BRIDGE_PORT</key><string>$ROUTER_PORT</string>
    <key>OPENCODE_PROVIDER</key><string>opencode-go</string>
    <key>OPENCODE_BRIDGE_TOKEN</key><string>$OPENCODE_BRIDGE_TOKEN</string>
    <key>PYTHONUNBUFFERED</key><string>1</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$REPO_DIR/logs/paid-router.log</string>
  <key>StandardErrorPath</key><string>$REPO_DIR/logs/paid-router.log</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$(id -u)" "$plist_dir/com.opencode.paid-router.plist"
  say "started $idx account servers + router (launchd). ports: $(IFS=,; echo "${ports[*]}") -> $ROUTER_PORT"
}

stop_all_macos() {
  for f in "$HOME/Library/LaunchAgents"/com.opencode.{serve-acc*,paid-router}.plist; do
    [[ -e "$f" ]] || continue
    launchctl bootout "gui/$(id -u)/$(basename "$f" .plist)" 2>/dev/null || true
  done
  say "services stopped"
}

start_all_macos() {
  for f in "$HOME/Library/LaunchAgents"/com.opencode.{serve-acc*,paid-router}.plist; do
    [[ -e "$f" ]] || continue
    launchctl bootstrap "gui/$(id -u)" "$f"
  done
  say "services started"
}

verify_all() {
  local free_port="${SERVE_PORT:-4090}"
  local route_port="$ROUTER_PORT"
  say "waiting for router on :$route_port ..."
  zone_wait_port "$route_port" || die "router not up — check $REPO_DIR/logs/paid-router.log"
  sleep 1
  local token
  source "$ENV_FILE"
  token="${OPENCODE_BRIDGE_TOKEN:?missing in $ENV_FILE}"
  local health
  health="$(curl -s -m 10 "http://127.0.0.1:$route_port/health" -H "Authorization: Bearer $token")"
  say "health: $health"
  echo "$health" | grep -q '"accounts_up": *[1-9]' || die "no serve instances reachable"
  # one live test through the pool
  local out
  out="$(curl -s -m 90 "http://127.0.0.1:$route_port/v1/chat/completions" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -d '{"model":"glm-5.3-flash","messages":[{"role":"user","content":"Reply ok"}]}')"
  echo "$out" | grep -q '"finish_reason":[[:space:]]*"stop"' || die "test failed: $out"
  say "test completion OK via pool: $(echo "$out" | head -c 220)"
}

cmd_remove() {
  local target="${1:?usage: remove <index|all>}"
  [[ "$target" == "all" ]] && {
    stop_all_linux 2>/dev/null || true
    rm -rf "$ACC_DIR"
    say "all accounts removed"
    return
  }
  local d="$ACC_DIR/$target"
  [[ -d "$d" ]] || die "no profile $target"
  rm -rf "$d"
  say "profile $target removed; re-run 'upgrade' to refresh port assignments"
}

# ---------------------------------------------------------------- main
cmd="${1:-list}"
case "$cmd" in
  add)      shift; cmd_add "$@" ;;
  list)     cmd_list ;;
  upgrade)  case "$PLATFORM" in linux) install_linux_all;; macos) install_macos_all;; esac; verify_all ;;
  stop)     case "$PLATFORM" in linux) stop_all_linux;; macos) stop_all_macos;; esac ;;
  start)    case "$PLATFORM" in linux) start_all_linux;; macos) start_all_macos;; esac ;;
  restart)
    case "$PLATFORM" in linux) stop_all_linux; start_all_linux;; macos) stop_all_macos; start_all_macos;; esac
    sleep 2; verify_all ;;
  remove)   shift; cmd_remove "$@" ;;
  *) die "usage: $0 add <auth.json> | list | upgrade | start | stop | restart | remove <index|all>" ;;
esac
