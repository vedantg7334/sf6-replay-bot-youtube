<#
    setup.ps1 - guided setup for the SF6 Replay Bot gaming-PC side.

    What it does automatically:
      - detects Python, OBS and the SF6 folder where it can;
      - asks for the values it can't guess, with sensible defaults;
      - writes config.json;
      - creates the Startup .bat so the agent launches at login;
      - adds the Windows Firewall rule for the agent port;
      - runs a final check and tells you what still needs doing by hand.

    What it does NOT do (these stay manual, by their nature):
      - install REFramework or the TRUE Faster StartUp mod;
      - enable Windows autologin or Wake-on-LAN in the BIOS;
      - enable the OBS WebSocket server;
      - create the Telegram bot or exchange the SSH key.
    It checks for these and reports, but can't perform them.

    Run from the windows/ folder:  powershell -ExecutionPolicy Bypass -File setup.ps1
#>

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Title($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($t)    { Write-Host "  [ok] $t"   -ForegroundColor Green }
function Warn($t)  { Write-Host "  [!]  $t"   -ForegroundColor Yellow }
function Info($t)  { Write-Host "  $t"        -ForegroundColor Gray }

# Ask with a default: Enter keeps the default shown in brackets.
function Ask($prompt, $default) {
    if ($default) {
        $a = Read-Host "$prompt [$default]"
        if ([string]::IsNullOrWhiteSpace($a)) { return $default }
        return $a
    }
    do { $a = Read-Host $prompt } while ([string]::IsNullOrWhiteSpace($a))
    return $a
}

function AskYesNo($prompt, $defaultYes = $true) {
    $hint = if ($defaultYes) { "Y/n" } else { "y/N" }
    $a = Read-Host "$prompt [$hint]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $defaultYes }
    return $a -match '^[yYsS]'
}

Write-Host "SF6 Replay Bot - gaming PC setup" -ForegroundColor White

# ---------------------------------------------------------------- detection

Title "Detecting what's already here"

# Find a REAL python.exe, skipping the Microsoft Store alias stub.
# The stub lives under ...\WindowsApps\ and does nothing useful - launching the
# agent through it silently fails, which is a classic trap.
function Find-RealPython {
    $candidates = @()
    foreach ($c in (Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
        $candidates += $c.Source
    }
    # common install roots as fallback
    $candidates += Get-ChildItem "$env:LOCALAPPDATA\Python\*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    $candidates += Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\*\python.exe" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p) -and ($p -notlike "*\WindowsApps\*")) {
            return $p
        }
    }
    return $null
}

$pythonExe = Find-RealPython
if ($pythonExe) {
    Ok "Python found: $pythonExe"
} else {
    Warn "No real Python found (only the Store stub, or none). Enter the path by hand."
    Warn "Tip: install python.org build, or find it with  py -0p"
}

# OBS in the usual spot
$obsGuess = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
if (Test-Path $obsGuess) { Ok "OBS found: $obsGuess" }
else { Warn "OBS not found at the default path"; $obsGuess = $null }

# SF6 folder: try common Steam library locations
$sf6Guess = $null
$steamCommon = @(
    "C:\Program Files (x86)\Steam\steamapps\common\Street Fighter 6",
    "D:\SteamLibrary\steamapps\common\Street Fighter 6",
    "E:\SteamLibrary\steamapps\common\Street Fighter 6"
)
foreach ($p in $steamCommon) {
    if (Test-Path $p) { $sf6Guess = $p; break }
}
if ($sf6Guess) { Ok "SF6 folder found: $sf6Guess" }
else { Warn "SF6 folder not auto-detected" }

# ---------------------------------------------------------------- questions

Title "Configuration"
Info "Press Enter to accept the value in brackets."

$pythonExe = Ask "Path to python.exe" $pythonExe
if ($pythonExe -like "*\WindowsApps\*") {
    Warn "That path is the Microsoft Store alias stub - the agent won't start from it."
    Warn "Enter the real interpreter (e.g. under $env:LOCALAPPDATA\Python\...)."
    $pythonExe = Ask "Path to a REAL python.exe" $null
}
$obsExe    = Ask "Path to obs64.exe"  $obsGuess
$sf6Dir    = Ask "SF6 folder"         $sf6Guess

$queueFile = Join-Path $sf6Dir "reframework\data\replay_queue.json"
Info "Queue file will be: $queueFile"

$agentDir  = Ask "Folder where you put agent.py / replayobs.py" $Here
$watcher   = Ask "Path to replayobs.py" (Join-Path $agentDir "replayobs.py")
$logFile   = Ask "Log file" (Join-Path $agentDir "agent.log")
$recDir    = Ask "OBS recording output folder" "$env:USERPROFILE\Videos"

Title "OBS WebSocket"
Info "In OBS: Tools -> WebSocket Server Settings. Copy the port and password here."
$obsHost   = Ask "OBS WebSocket host" "localhost"
$obsPort   = Ask "OBS WebSocket port" "4455"
$obsPass   = Ask "OBS WebSocket password" $null

Title "Network binding"
Info "Use the VPN (e.g. Tailscale) address of THIS PC, not 0.0.0.0."
Info "Find it with:  tailscale ip -4"
$bind      = Ask "Bind address for the agent" "127.0.0.1"
$port      = Ask "Agent port" "8770"

Title "Sync to a server (optional, off by default in this YouTube-only build)"
$syncOn = AskYesNo "Enable video sync to a server?" $false
if ($syncOn) {
    $sshKey   = Ask "SSH private key" "$env:USERPROFILE\.ssh\sf6sync"
    $sshDest  = Ask "SSH destination (user@server)" $null
    $remoteDir = Ask "Remote folder on the server" "/path/on/server/sf6replays"
} else {
    $sshKey = "~\.ssh\sf6sync"; $sshDest = ""; $remoteDir = ""
}

Title "YouTube upload"
$ytOn = AskYesNo "Enable YouTube upload?" $true
if ($ytOn) {
    Info "You need an OAuth client_secret JSON from Google Cloud Console."
    $ytSecret  = Ask "Path to the client_secret JSON" "$agentDir\yt_client_secret.json"
    $ytToken   = Ask "Where to save the login token" "$agentDir\yt_token.json"
    $ytPrivacy = Ask "Video privacy (private/unlisted/public)" "private"
} else {
    $ytSecret = "$agentDir\yt_client_secret.json"; $ytToken = "$agentDir\yt_token.json"; $ytPrivacy = "private"
}

# ---------------------------------------------------------------- write config.json

Title "Writing config.json"

$config = [ordered]@{
    queue_file     = $queueFile
    obs_exe        = $obsExe
    watcher_script = $watcher
    log_file       = $logFile
    rec_dir        = $recDir
    sent_subdir    = "sent"
    video_ext      = @(".mp4", ".mkv", ".mov", ".flv")
    obs_websocket  = [ordered]@{
        host     = $obsHost
        port     = [int]$obsPort
        password = $obsPass
    }
    recording      = [ordered]@{
        max_seconds           = 600
        heartbeat_timeout_sec = 8
        heartbeat_grace_sec   = 15
    }
    sync           = [ordered]@{
        enabled     = $syncOn
        ssh_key     = $sshKey
        destination = $sshDest
        remote_dir  = $remoteDir
    }
    youtube        = [ordered]@{
        enabled        = $ytOn
        client_secret  = $ytSecret
        token_file     = $ytToken
        privacy        = $ytPrivacy
        uploaded_subdir = "uploaded"
    }
    steam_appid          = "1364780"
    obs_startup_wait_sec = 15
    bind                 = $bind
    port                 = [int]$port
}

$configPath = Join-Path $agentDir "config.json"
if (Test-Path $configPath) {
    if (-not (AskYesNo "config.json already exists. Overwrite?" $false)) {
        Warn "Keeping the existing config.json - skipping write"
        $configPath = $null
    }
}
if ($configPath) {
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
    Ok "Written: $configPath"
}

# ---------------------------------------------------------------- startup .bat

Title "Startup entry"
if (AskYesNo "Create the Startup .bat so the agent launches at login?" $true) {
    $pythonw = Join-Path (Split-Path $pythonExe) "pythonw.exe"
    if (-not (Test-Path $pythonw)) {
        Warn "pythonw.exe not found next to python.exe - using python.exe (a console will stay open)"
        $pythonw = $pythonExe
    }
    $agentPy = Join-Path $agentDir "agent.py"
    $startup = [Environment]::GetFolderPath("Startup")
    $batPath = Join-Path $startup "sf6-agent.bat"
    "@echo off`r`nstart """" ""$pythonw"" ""$agentPy""" | Set-Content -Path $batPath -Encoding ASCII
    Ok "Written: $batPath"
    Info "The agent will start at your next login. To start it now, double-click the .bat."
}

# ---------------------------------------------------------------- firewall

Title "Firewall"
if (AskYesNo "Add the inbound firewall rule for port $port?" $true) {
    try {
        $existing = Get-NetFirewallRule -DisplayName "SF6 agent" -ErrorAction SilentlyContinue
        if ($existing) {
            Ok "Rule 'SF6 agent' already exists"
        } else {
            New-NetFirewallRule -DisplayName "SF6 agent" -Direction Inbound `
                -Protocol TCP -LocalPort $port -Action Allow | Out-Null
            Ok "Firewall rule added for port $port"
        }
    } catch {
        Warn "Couldn't add the rule (run PowerShell as Administrator): $_"
    }
}

# ---------------------------------------------------------------- final check

Title "Final check - what still needs doing by hand"

# REFramework present?
if ($sf6Dir -and (Test-Path (Join-Path $sf6Dir "dinput8.dll"))) {
    Ok "REFramework looks installed (dinput8.dll present)"
} else {
    Warn "REFramework not detected - install it into the SF6 folder"
}

# Lua scripts in autorun?
$autorun = Join-Path $sf6Dir "reframework\autorun"
if (Test-Path (Join-Path $autorun "orchestrator.lua")) {
    Ok "orchestrator.lua is in autorun"
} else {
    Warn "Copy orchestrator.lua and recon.lua into $autorun"
}

# obsws-python installed for that interpreter?
try {
    & $pythonExe -c "import obsws_python" 2>$null
    if ($LASTEXITCODE -eq 0) { Ok "obsws-python is installed" }
    else { Warn "obsws-python missing - run:  `"$pythonExe`" -m pip install obsws-python" }
} catch {
    Warn "Couldn't check obsws-python - run:  `"$pythonExe`" -m pip install obsws-python"
}

# SSH key present, if sync enabled
if ($syncOn) {
    if (Test-Path $sshKey) {
        Ok "SSH key present: $sshKey"
        Info "Make sure its .pub is in authorized_keys on the server, and test:"
        Info "  ssh -i `"$sshKey`" $sshDest `"echo ok`""
    } else {
        Warn "SSH key not found - create it with:"
        Info "  ssh-keygen -t ed25519 -f `"$sshKey`" -N '`"`"'"
    }
}

# YouTube setup reminder
if ($ytOn) {
    if (Test-Path $ytSecret) {
        Ok "YouTube client secret present"
        Info "Run yt_auth.py once to create the token:  `"$pythonExe`" `"$agentDir\yt_auth.py`""
    } else {
        Warn "YouTube client secret not found at $ytSecret"
        Info "Download it from Google Cloud Console (OAuth client, Desktop app)."
    }
}

# Bind sanity
if ($bind -eq "0.0.0.0" -or $bind -eq "127.0.0.1") {
    Warn "bind is '$bind': 127.0.0.1 works only locally, 0.0.0.0 exposes the agent to the whole LAN."
    Info "For remote use, set it to this PC's VPN address (tailscale ip -4)."
}

Write-Host "`nStill manual, outside this script's reach:" -ForegroundColor White
Info "- TRUE Faster StartUp mod (required: gets past the title screen to mode select)"
Info "- Windows autologin (netplwiz) and Wake-on-LAN in the BIOS"
Info "- OBS WebSocket server enabled"
Info "- Telegram bot created with BotFather, and the server-side .env filled in"

Write-Host "`nSetup done." -ForegroundColor White
Info "Start the agent (double-click the Startup .bat), then from the server: /diag"
