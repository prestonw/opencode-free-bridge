# Windows installer for opencode-free-bridge (run in PowerShell as a normal user)
# Usage:
#   powershell -ExecutionPolicy Bypass -File windows-install.ps1          # install both stacks
#   ... -FreeOnly                                                         # just the keyless free bridge
#   ... -Uninstall                                                        # remove scheduled tasks (keeps data)
param(
  [switch]$FreeOnly,
  [switch]$Uninstall
)
$ErrorActionPreference = "Stop"
$Repo   = Split-Path -Parent $MyInvocation.MyCommand.Path
$EnvFile = Join-Path $Repo "bridge.env"
$Logs   = Join-Path $Repo "logs"
New-Item -ItemType Directory -Force -Path $Logs, (Join-Path $Repo "data"), (Join-Path $Repo "accounts") | Out-Null

function Say($m) { Write-Host "[opencode-windows] $m" }
function Die($m) { Write-Host "[opencode-windows] ERROR: $m" -ForegroundColor Red; exit 1 }

# ---- platform bits -----------------------------------------------------------
$Python = (Get-Command python  -ErrorAction SilentlyContinue).Source
if (-not $Python) { $Python = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $Python) { Die "python3 not on PATH (winget install Python.Python.3)" }
$BridgeScript = Join-Path $Repo "opencode_bridge.py"
$RouterScript = Join-Path $Repo "opencode_paid_router.py"
$ServeEnv  = "XDG_DATA_HOME=$(Join-Path $Repo 'data\opencode-share');XDG_CONFIG_HOME=$(Join-Path $Repo 'data\opencode-config')"

function Ensure-OpenCode {
  $cmd = Get-Command opencode -ErrorAction SilentlyContinue
  if (-not $cmd) {
    Say "installing opencode-ai via npm"
    npm i -g opencode-ai 2>$null
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) { Die "npm -g failed; install Node.js and 'npm i -g opencode-ai' manually" }
  }
  return (Get-Command opencode).Source
}

function Ensure-Token {
  if (Test-Path $EnvFile) {
    $existing = (Get-Content $EnvFile | Where-Object { $_ -match '^OPENCODE_BRIDGE_TOKEN=(.+)$' })
    if ($existing) { Say "reusing existing bridge token"; return }
  }
  $bytes = New-Object byte[] 24
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $token = [Convert]::ToBase64String($bytes).Replace("+","").Replace("/","").Replace("=","")
  Set-Content -Path $EnvFile -Value "OPENCODE_BRIDGE_TOKEN=$token`nOPENCODE_SERVER_URL=http://127.0.0.1:4090" -NoNewline
  Say "generated token -> $EnvFile"
}

function Register-Task($name, $command, $args) {
  $action  = New-ScheduledTaskAction -Execute $command -Argument $args -WorkingDirectory $Repo
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName $name
}
function Remove-Task($name) {
  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}

# ---- service registration (scheduled tasks) ----------------------------------
function Install-Free {
  $oc = Ensure-OpenCode
  Ensure-Token
  $serveData  = Join-Path $Repo "data\opencode-share"
  $serveConf  = Join-Path $Repo "data\opencode-config"
  New-Item -ItemType Directory -Force -Path $serveData, $serveConf | Out-Null

  # Free tier MUST be keyless — refuse to install if someone copied auth.json in
  if (Test-Path (Join-Path $serveData "opencode\auth.json")) { Die "data\opencode-share\opencode\auth.json exists; free tier must run keyless — remove it" }

  # cmd /c wrapper lets us set env vars per-task (Task Scheduler actions don't take env)
  $serveCmd = "set XDG_DATA_HOME=$serveData&& set XDG_CONFIG_HOME=$serveConf&& `"$oc`" serve --port 4090 --hostname 127.0.0.1"
  Register-Task "OpencodeServe" "cmd.exe" "/c $serveCmd"
  Register-Task "OpencodeBridge" $Python "`"$BridgeScript`""
  Say "scheduled: OpencodeServe (:4090, keyless data dir) + OpencodeBridge (:4059)"
}

function Install-PaidPool {
  $accounts = Get-ChildItem (Join-Path $Repo "accounts") -Directory -ErrorAction SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName "auth.json") }
  if (-not $accounts) { Say "no accounts registered (accounts/<n>/auth.json missing) — skipping paid pool"; return }
  $ports = @()
  $i = 0
  foreach ($acc in $accounts) {
    $i++
    $port = 4090 + $i          # 4091.., 4090 = free-tier serve
    $share = Join-Path $acc.FullName "xdg-share"
    $conf  = Join-Path $acc.FullName "xdg-config"
    New-Item -ItemType Directory -Force -Path (Join-Path $share "opencode"), $conf | Out-Null
    # load auth.json into the profile's xdg-share before service starts (so serve sees its keys)
    Copy-Item -Force (Join-Path $acc.FullName "auth.json") (Join-Path $share "opencode\auth.json")
    $oc = Ensure-OpenCode
    $accCmd = "set XDG_DATA_HOME=$share&& set XDG_CONFIG_HOME=$conf&& `"$oc`" serve --port $port --hostname 127.0.0.1"
    Register-Task "OpencodeServeAcc$i" "cmd.exe" "/c $accCmd"
    $ports += $port
  }
  $routerCmd = "set OPENCODE_SERVE_PORTS=$($ports -join ',')&& set OPENCODE_BRIDGE_PORT=4060&& set OPENCODE_PROVIDER=opencode-go&& `"$Python`" `"$RouterScript`""
  Register-Task "OpencodePaidRouter" "cmd.exe" "/c $routerCmd"
  Say "scheduled $i account serves ($($ports -join ',')) + PaidRouter (:4060)"
}

function Do-Uninstall {
  foreach ($t in @("OpencodeServe","OpencodeBridge","OpencodePaidRouter") ) { Remove-Task $t }
  Get-ScheduledTask -TaskName "OpencodeServeAcc*" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Task $_.TaskName }
  Say "scheduled tasks removed (data kept)"
}

# ---- main --------------------------------------------------------------------
if ($Uninstall) { Do-Uninstall; exit 0 }
Install-Free
if (-not $FreeOnly) { Install-PaidPool }
Say "done. free bridge :4059/v1  · paid pool :4060/v1  · token in bridge.env"
