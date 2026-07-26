# SF6 Replay Bot (YouTube-only)

End-to-end automation for Street Fighter 6 replays: one Telegram command wakes the PC,
records the replays by ID with OBS, and uploads them to YouTube titled with the players'
nicknames and the replay ID. Uses REFramework to drive the game from the inside.

Once you send the bot a replay ID (for example from [sfbuff.site](https://sfbuff.site)),
everything after that runs on its own: your home PC wakes itself up, opens SF6, finds
the replay, records it with OBS, and uploads the finished video to your YouTube channel
(as a private video), sending you the link back on Telegram. The only manual step is
the command itself — from there to the finished upload, you don't touch anything.

Handy when you're at a tournament and want to review an opponent's matches without
carrying your PC around, or without a home server to store the videos on.

This is the **YouTube-only** variant: there's no local storage server, no Jellyfin, no
sync step. Everything lands on YouTube and that's it. If you'd rather also keep a local
copy on a server (with Jellyfin as a media library), see *Optional: also add local
storage + Jellyfin* near the end - the agent already supports it, you just need a
different bot and a couple of settings.

```
Telegram  ──►  bot (Linux server)  ──►  HTTP agent (Windows PC)
                                              │
                                              ├─► OBS (obs-websocket)
                                              ├─► SF6 + REFramework (Lua)
                                              └─► YouTube upload ──► link back to you
```

## How it works

The heavy lifting all happens on the gaming PC: OBS records, and two Lua scripts
loaded by REFramework drive the game from the inside.

`orchestrator.lua` is a state machine that navigates the menus: from the title
screen to the replay search, it enters the ID, opens the entry, starts playback and
at the end moves on to the next replay in the queue. Screen state is read from
`UIFlowManager`, which exposes the name of the active flow — far more reliable than
trying to interpret the UI.

`recon.lua` hooks `BattleReplayController.Start` and `.End`, so recording starts and
stops exactly on the first and last frame of the match, with no wasted margins. It
also extracts the players' names, used to rename the file.

The Python script `replayobs.py` bridges to OBS over obs-websocket and renames the
recorded files. `agent.py` is a small HTTP server that receives commands from the
bot, and also handles the YouTube upload. On the Linux server, `bot.py` runs in
Docker and talks to the agent across the VPN.

## Requirements

**Gaming PC (Windows)**

- Street Fighter 6 on Steam
- [REFramework](https://github.com/praydog/REFramework) installed for SF6
- The **TRUE Faster StartUp** mod (required — see the note below)
- OBS Studio with the WebSocket server enabled (Tools → WebSocket Server Settings)
- Python 3.11 or newer, with `pip install obsws-python google-auth-oauthlib google-api-python-client`
- Wake-on-LAN enabled in the BIOS and in the network adapter properties
- Windows automatic login configured (see *Security* below)

**Google / YouTube**

- A Google Cloud project with the **YouTube Data API v3** enabled
- An OAuth client (type: Desktop app) — see *YouTube setup* below
- A YouTube channel to upload to

**Server**

- Linux with Docker and Docker Compose
- On the same LAN as the gaming PC (needed for the WoL magic packet)
- A Telegram bot created with [@BotFather](https://t.me/BotFather)

**Both**

- A mesh VPN such as [Tailscale](https://tailscale.com), to reach the PC from outside home

## Installation

### 1. Gaming PC

Copy `windows/agent.py`, `windows/replayobs.py`, `windows/yt_auth.py` and
`windows/config.example.json` into a dedicated folder, for example `C:\sf6\`. Don't put
them inside the game folder: a Steam update could wipe them.

The `windows/setup.ps1` script automates most of what follows: it detects a real Python
interpreter (skipping the Microsoft Store alias stub, a common trap), asks for the
remaining values including the YouTube ones, writes `config.json`, creates the Startup
entry and the firewall rule, and finishes with a check of what's still manual. The
easiest way to run it is to double-click `windows/install.bat`, which elevates to
administrator (needed for the firewall rule) and launches the setup. Or run it directly:

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

If you'd rather do it by hand, the manual steps are below.

Copy the Lua scripts into `<SF6 folder>\reframework\autorun\`.

Install the **TRUE Faster StartUp** mod. This one is not optional: SF6's "press any
button" title screen reads input at the OS level, so the orchestrator cannot get past
it from inside the game and would hang there. The mod skips the title screen and drops
the game straight at the **mode select** menu, which is the point the orchestrator
knows how to navigate from. Without it, remote/autopilot startup does not work.

Rename `config.example.json` to `config.json` and fill it in. A few things to watch:

- `password` under `obs_websocket` is the password of the OBS WebSocket server
  (Tools → WebSocket Server Settings). It's a secret: that's why `config.json` is
  excluded from version control.
- `bind` should be set to the PC's VPN address, **not** `0.0.0.0` (see *Security*).
- `sync.enabled` is `false` by default in this variant — leave it, unless you're
  following the optional Jellyfin section below.
- the `youtube` block needs `client_secret` pointing at the OAuth JSON you download
  from Google Cloud Console, and `token_file` for where the login token gets saved.

To have the agent start at login, create a `.bat` in the Startup folder
(`Win+R` → `shell:startup`):

```bat
@echo off
start "" "C:\path\to\pythonw.exe" "C:\sf6\agent.py"
```

`pythonw.exe`, not `python.exe`: it runs the agent without a console window.
For the exact interpreter path: `python -c "import sys; print(sys.executable)"`.

**Watch out for the Microsoft Store stub.** If that command prints a path under
`...\WindowsApps\`, that's not a real interpreter — it's the Store alias, and the
agent launched through it will *appear* to start but never actually listen. Use a
real install instead (python.org, or `...\AppData\Local\Python\...`). This is the
single most common reason the agent "starts but doesn't respond". A brief CMD window
that flashes open and closes at login is normal, by the way — that's the `.bat`
finishing after handing off to `pythonw`, not an error.

Open the port in Windows Firewall:

```powershell
New-NetFirewallRule -DisplayName "SF6 agent" -Direction Inbound -Protocol TCP -LocalPort 8770 -Action Allow
```

### 2. YouTube setup

In [Google Cloud Console](https://console.cloud.google.com):

1. Create a project, then enable the **YouTube Data API v3** (Library → search → Enable).
2. Configure the **OAuth consent screen** (Google Auth Platform → Overview if it's your
   first client): user type External, add the scope
   `https://www.googleapis.com/auth/youtube.upload`, and add your own Google account
   under **Audience → Test users** — without this, login will fail with `access_denied`.
   While the app is in "Testing" mode the login token expires after about 7 days; you
   can publish the app (no full audit needed) to remove that limit, since publishing
   without verification only affects sensitive-scope apps used by *other* people — for
   personal use it works fine.
3. Create credentials: **Client** → **Create OAuth client** → type **Desktop app**.
   Download the JSON and save it as `C:\sf6\yt_client_secret.json`.
4. Run the one-time login: `python C:\sf6\yt_auth.py`. It opens a browser, you
   authorize with the account that owns the target channel, and it saves
   `C:\sf6\yt_token.json`. Re-run this whenever uploads start failing with an auth
   error (expected about once a week if the app is still in Testing mode).

Videos are uploaded as **private** by default (`youtube.privacy` in `config.json`).
Making them public or unlisted through the API requires Google's full app verification
(a domain, a privacy policy, sometimes a demo video, weeks to months of review) — for
a personal replay archive it's rarely worth it. Private is also the setting that keeps
working without any of that.

### 3. Server

```bash
git clone https://github.com/USER/sf6-replay-bot-youtube.git
cd sf6-replay-bot-youtube/server
cp .env.example .env
$EDITOR .env
docker compose up -d --build
```

`network_mode: host` in the compose file is not optional: it's needed because the WoL
magic packet must go out as a broadcast on the local network, which is impossible from
a Docker bridge network, and so the container can use the host's VPN interface.

**`AGENT_URL` must be an IP, not a hostname.** The bot runs inside Docker, and the
container can't resolve Tailscale MagicDNS hostnames even though the host machine can.
Use the Tailscale IP of the gaming PC (`tailscale ip -4` on the PC), not its name.

## Bot commands

| Command | What it does |
|---|---|
| `/on` | Wakes the PC via Wake-on-LAN and launches OBS, watcher and SF6 |
| `/rec ID [ID ...]` | Adds one or more replays to the queue; the orchestrator starts on its own |
| `/queue` | Shows the current queue |
| `/status` | Status of PC, processes, queue and videos pending upload |
| `/upload` | Uploads the videos to YouTube now |
| `/diag` | Paths configured on the agent, to see what's off |
| `/off` | Shuts down the PC, with a 30-second grace period |

After a `/rec` the bot watches the queue in the background: when it empties and the
files stop changing size for 90 seconds, it uploads them to YouTube and sends you back
the links.

## Security

Three trade-offs worth being explicit about.

**Windows automatic login** is necessary — Wake-on-LAN powers the PC on but leaves it
at the lock screen, and no magic packet can type a password. The price is that anyone
physically at that PC gets in without credentials. On a home gaming machine that's
usually an acceptable risk, less so if you keep sensitive data on it.

**The HTTP agent has no authentication.** Anyone who can reach that port can launch the
game, write the queue or shut the PC down. That's why `bind` must be set to the VPN
address and not `0.0.0.0`: that way the port only exists on the private network and the
home LAN can't see it.

**The bot only answers your chat ID**, checked on every message. Unauthorized users are
silently ignored. The token, though, must be treated like a password: whoever has it
can read the messages you send the bot and write to you impersonating it. Never commit
the `.env`, and if the token leaks anywhere revoke it with `/revoke` on BotFather.

## Optional: also add local storage + Jellyfin

`agent.py` already supports copying the recorded videos to a server over SSH — the
`/sync` endpoint and the `do_sync()` logic are built in and unused by default in this
variant, not removed. To turn it on:

1. In `config.json`, set `sync.enabled` to `true` and fill in `ssh_key`,
   `destination` (`user@server`) and `remote_dir`.
2. Generate a dedicated SSH key and copy it to the server's `authorized_keys`, the same
   way you would for any passwordless scp setup:
   ```powershell
   ssh-keygen -t ed25519 -f $env:USERPROFILE\.ssh\sf6sync -N '""'
   ```
   ```bash
   echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys
   ```
3. On the server, create a folder under a media library already mounted into your
   Jellyfin container, with the same owner as the rest of the library (usually
   `PUID:PGID` from its compose file), and add it as a library of type **Home videos
   and photos** — not "Movies", or Jellyfin will look the titles up on TMDB and fill
   the library with wrong matches. Disable the metadata and image downloaders too.
4. The `bot.py` in this repo doesn't call `/sync` on its own or expose a `/sync`
   command — it only drives the YouTube upload automatically. To trigger a sync you
   can call the agent directly:
   ```bash
   curl -s -X POST http://<agent-ip>:8770/sync
   ```
   or add back a `cmd_sync` command and a Jellyfin-refresh step in `bot.py`, mirroring
   how `cmd_upload` is written — it's the same shape, just calling `/sync` instead of
   `/upload` and then hitting Jellyfin's `Library/Refresh` API with an API key from
   Dashboard → Advanced → API Keys.

## Known limitations

- The "press any button" screen at startup can't be bypassed from inside the game,
  because it reads input at the operating-system level. This is why the TRUE Faster
  StartUp mod is a hard requirement (see Installation); `pydirectinput` from outside is
  the only in-house alternative.
- If OBS takes longer than expected to open the WebSocket server, the watcher may start
  too early and exit. Tune it with `obs_startup_wait_sec` in the config.
- YouTube's daily upload quota (`videos.insert`) is separate from the general API quota
  and defaults to about 100 uploads/day per project — plenty for normal use, but check
  your own project's quota in Cloud Console (API & Services → Quotas) if uploads start
  failing.
- Tested on a single setup. SF6's internal flow names can change with game patches, and
  in that case the orchestrator needs updating.

## Troubleshooting

Real issues hit during setup, and what they actually were:

**Bot replies to some commands but not others, or answers in bursts.** The bot was
processing updates one at a time; a command that waits (like `/on` waiting for the PC
to boot) blocked everything behind it. Fixed in the code with `concurrent_updates(True)`
- make sure you're running the current `bot.py`.

**Bot says "PC unreachable" but `curl` to the agent works from the server.** The bot
runs inside Docker, and the container can't resolve MagicDNS hostnames (like `my-pc`)
even though the host can. Use the Tailscale **IP** in `AGENT_URL`, not the hostname.
Test from inside the container:
`docker compose exec sf6-bot sh -c "curl -s http://100.x.x.x:8770/status"`.

**Agent "starts" at login but never responds.** Almost always the `.bat` points at the
Microsoft Store Python stub under `...\WindowsApps\`. Use a real interpreter (see
Installation). Confirm the agent is actually listening: from the server,
`curl -s http://100.x.x.x:8770/status` should return JSON.

**`/on` powers on the PC but the programs don't launch.** Test the chain in isolation:
`curl -s -X POST http://100.x.x.x:8770/launch` calls the agent directly, skipping the
bot. If the apps open, the agent is fine and the problem is bot->agent (see the two
items above). If they don't, check `agent.log` on the PC.

**config.json errors after editing.** PowerShell's `Set-Content`/`Out-File` can add a
UTF-8 BOM that Python rejects. Re-save without BOM, or edit in Notepad. Validate with:
`Get-Content C:\sf6\config.json -Raw | ConvertFrom-Json | Out-Null`.

**yt_auth.py opens and closes instantly.** Run it from an already-open PowerShell so the
error stays visible, not by double-click. Usual causes: Google libs not installed for
that interpreter, or `client_secret` path wrong in config.json.

## Credits

This project wouldn't exist without the people who pointed me in the right direction.
Thanks to the **Haven's Night** Discord, where I first asked around, and to **Wael**,
who answered and showed me rkaganda's work — without that nudge I'd never have found the
pieces this is built on.

The reverse engineering of SF6's internal structures started by observing
[sf6_replays_data](https://github.com/rkaganda/sf6_replays_data) by **rkaganda**, which
was the most useful reference for figuring out where to begin.

The **TRUE Faster StartUp** mod by **MafuyuKinoshita** is what makes remote startup
possible at all — it gets the game past the title screen to the mode select menu, which
the orchestrator can't do on its own.

Built on [REFramework](https://github.com/praydog/REFramework) by **praydog**.

## Disclaimer

Unofficial project, not affiliated with Capcom in any way. It uses mods and hooks into
the internal structures of a game with an online component: use at your own risk. It
does not modify gameplay or interfere with matchmaking, but Capcom's stance on mods
isn't always clear and the responsibility stays with whoever installs it.

## License

MIT — see [LICENSE](LICENSE).
