#!/usr/bin/env python3
"""
agent.py - HTTP agent running on the gaming PC.

Receives commands from the Telegram bot (which runs on the server) and executes
them locally: launching OBS / watcher / SF6, writing the replay queue, syncing
recorded videos to the server, uploading them to YouTube, shutting down.

All configuration lives in config.json, next to this file.
See config.example.json for the template.
"""

import json
import os
import pathlib
import subprocess
import sys
import threading
import time
import traceback
import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

# ---------------------------------------------------------------- config

BASE_DIR = pathlib.Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "config.json"


def load_config():
    if not CONFIG_FILE.exists():
        print(f"ERROR: {CONFIG_FILE} is missing")
        print("Copy config.example.json to config.json and adjust the paths.")
        sys.exit(1)
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"ERROR: config.json is not valid JSON: {e}")
        sys.exit(1)


CFG = load_config()


def as_path(value):
    """Expand ~ and environment variables, then return a Path."""
    return pathlib.Path(os.path.expandvars(os.path.expanduser(str(value))))


QUEUE = as_path(CFG["queue_file"])
OBS = as_path(CFG["obs_exe"])
WATCHER = as_path(CFG["watcher_script"])
LOGFILE = as_path(CFG["log_file"])

REC_DIR = as_path(CFG["rec_dir"])
SENT_DIR = REC_DIR / CFG.get("sent_subdir", "sent")
VIDEO_EXT = {e.lower() for e in CFG.get("video_ext", [".mp4", ".mkv"])}

SYNC = CFG.get("sync", {})
SYNC_ON = bool(SYNC.get("enabled", False))
SSH_KEY = as_path(SYNC.get("ssh_key", "~/.ssh/id_ed25519"))
SSH_DEST = SYNC.get("destination", "")
DEST_DIR = SYNC.get("remote_dir", "")

YT = CFG.get("youtube", {})
YT_ON = bool(YT.get("enabled", False))
YT_CLIENT_SECRET = as_path(YT.get("client_secret", "")) if YT.get("client_secret") else None
YT_TOKEN_FILE = as_path(YT.get("token_file", "")) if YT.get("token_file") else None
YT_PRIVACY = YT.get("privacy", "private")
YT_UPLOADED_SUBDIR = YT.get("uploaded_subdir", "uploaded")

STEAM_APPID = str(CFG.get("steam_appid", "1364780"))
OBS_STARTUP_WAIT = int(CFG.get("obs_startup_wait_sec", 15))
BIND = CFG.get("bind", "127.0.0.1")
PORT = int(CFG.get("port", 8770))

# the agent runs under pythonw (no console); the watcher we want WITH a console
PYTHON = pathlib.Path(sys.executable).with_name("python.exe")

NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW: avoids console windows flashing

watcher_proc = None
sync_lock = threading.Lock()
upload_lock = threading.Lock()


# ---------------------------------------------------------------- helpers

def log(msg):
    line = f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    print(line, flush=True)
    try:
        LOGFILE.parent.mkdir(parents=True, exist_ok=True)
        with LOGFILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def running(name):
    try:
        out = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {name}"],
            capture_output=True, text=True, creationflags=NO_WINDOW,
        ).stdout
        return name.lower() in out.lower()
    except Exception as e:
        log(f"ERROR tasklist {name}: {e}")
        return False


def watcher_running():
    return watcher_proc is not None and watcher_proc.poll() is None


# ---------------------------------------------------------------- launch

def launch_all():
    """Launch OBS, watcher and SF6. Each step is isolated: if one fails,
    the others start anyway and the error goes to the log."""
    global watcher_proc

    try:
        if running("obs64.exe"):
            log("OBS already running")
        elif not OBS.exists():
            log(f"ERROR: OBS not found at {OBS}")
        else:
            log("launching OBS")
            subprocess.Popen([str(OBS), "--minimize-to-tray"], cwd=str(OBS.parent))
            time.sleep(OBS_STARTUP_WAIT)
    except Exception:
        log("ERROR launching OBS:\n" + traceback.format_exc())

    try:
        if not WATCHER.exists():
            log(f"ERROR: watcher not found at {WATCHER}")
        elif watcher_running():
            log("watcher already active")
        else:
            log("launching watcher")
            watcher_proc = subprocess.Popen(
                [str(PYTHON), str(WATCHER)],
                cwd=str(WATCHER.parent),
                creationflags=subprocess.CREATE_NEW_CONSOLE,
            )
    except Exception:
        log("ERROR launching watcher:\n" + traceback.format_exc())

    try:
        if running("StreetFighter6.exe"):
            log("SF6 already running")
        else:
            log("launching SF6")
            subprocess.Popen(
                ["cmd", "/c", f"start steam://rungameid/{STEAM_APPID}"],
                creationflags=NO_WINDOW,
            )
    except Exception:
        log("ERROR launching SF6:\n" + traceback.format_exc())

    log("launch_all done")


# ---------------------------------------------------------------- queue

def set_queue(ids):
    QUEUE.parent.mkdir(parents=True, exist_ok=True)
    clean = [str(i).strip() for i in ids if str(i).strip()]
    QUEUE.write_text(json.dumps({"ids": clean}), encoding="utf-8")
    log(f"queue written: {clean}")
    return clean


def read_queue():
    try:
        return json.loads(QUEUE.read_text(encoding="utf-8"))
    except Exception:
        return {"ids": []}


# ---------------------------------------------------------------- sync

def pending_files():
    """Videos present in rec_dir and not yet sent."""
    if not REC_DIR.exists():
        return []
    return sorted(
        p for p in REC_DIR.iterdir()
        if p.is_file() and p.suffix.lower() in VIDEO_EXT
    )


def files_signature():
    """name->size fingerprint. If it doesn't change, nobody is writing:
    that's the signal that recording is finished."""
    out = {}
    for p in pending_files():
        try:
            out[p.name] = p.stat().st_size
        except OSError:
            pass
    return out


def do_sync():
    """Copy the videos to the server via scp and move the sent ones into a
    subfolder, so they aren't copied again on the next sync."""
    if not SYNC_ON:
        return {"ok": False, "error": "sync disabled in config.json"}
    if not SSH_DEST or not DEST_DIR:
        return {"ok": False, "error": "sync destination not configured"}
    if not sync_lock.acquire(blocking=False):
        return {"ok": False, "error": "sync already in progress"}

    sent, failed = [], []
    try:
        files = pending_files()
        if not files:
            return {"ok": True, "sent": [], "failed": [],
                    "note": "nothing to send"}

        SENT_DIR.mkdir(parents=True, exist_ok=True)
        for f in files:
            cmd = [
                "scp", "-i", str(SSH_KEY),
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                str(f), f"{SSH_DEST}:{DEST_DIR}/",
            ]
            r = subprocess.run(cmd, capture_output=True, text=True,
                               creationflags=NO_WINDOW, timeout=1800)
            if r.returncode == 0:
                try:
                    f.replace(SENT_DIR / f.name)
                except Exception as e:
                    log(f"sent but not moved {f.name}: {e}")
                sent.append(f.name)
                log(f"sent {f.name}")
            else:
                failed.append(f.name)
                log(f"ERROR scp {f.name}: {r.stderr.strip()[:300]}")

        return {"ok": not failed, "sent": sent, "failed": failed}
    except Exception:
        log("ERROR sync:\n" + traceback.format_exc())
        return {"ok": False, "sent": sent, "failed": failed,
                "error": "exception, see the log"}
    finally:
        sync_lock.release()


# ---------------------------------------------------------------- youtube upload

def yt_title_from_name(stem):
    """The watcher already names files 'Nick1 vs Nick2 ID', which is a fine
    YouTube title as-is. This hook is here in case you want to tweak it."""
    return stem


def uploaded_source_dir():
    """Where the to-upload videos live: after a sync they've been moved into
    SENT_DIR, so that's the folder to upload from. If sync is off, upload
    straight from REC_DIR."""
    return SENT_DIR if SYNC_ON else REC_DIR


def pending_uploads():
    src = uploaded_source_dir()
    if not src.exists():
        return []
    return sorted(
        p for p in src.iterdir()
        if p.is_file() and p.suffix.lower() in VIDEO_EXT
    )


def get_youtube_service():
    """Build an authenticated YouTube client from the saved token, refreshing
    it if needed. Returns None (and logs) if auth isn't set up."""
    try:
        from google.oauth2.credentials import Credentials
        from google.auth.transport.requests import Request
        from googleapiclient.discovery import build
    except ImportError:
        log("ERROR: google api libs missing. Run: pip install "
            "google-auth-oauthlib google-api-python-client")
        return None

    if not YT_TOKEN_FILE or not YT_TOKEN_FILE.exists():
        log(f"ERROR: YouTube token not found at {YT_TOKEN_FILE}. "
            "Run yt_auth.py once to create it.")
        return None

    try:
        creds = Credentials.from_authorized_user_file(
            str(YT_TOKEN_FILE),
            ["https://www.googleapis.com/auth/youtube.upload"],
        )
        if not creds.valid:
            if creds.expired and creds.refresh_token:
                creds.refresh(Request())
                YT_TOKEN_FILE.write_text(creds.to_json(), encoding="utf-8")
                log("YouTube token refreshed")
            else:
                log("ERROR: YouTube token invalid and can't refresh. "
                    "Re-run yt_auth.py (testing-mode tokens expire after ~7 days).")
                return None
        return build("youtube", "v3", credentials=creds)
    except Exception:
        log("ERROR building YouTube service:\n" + traceback.format_exc())
        return None


def upload_one(service, path):
    """Upload a single file with resumable upload. Returns the video id."""
    from googleapiclient.http import MediaFileUpload
    from googleapiclient.errors import HttpError

    title = yt_title_from_name(path.stem)
    body = {
        "snippet": {"title": title, "description": "", "categoryId": "20"},  # 20 = Gaming
        "status": {"privacyStatus": YT_PRIVACY, "selfDeclaredMadeForKids": False},
    }
    media = MediaFileUpload(str(path), chunksize=-1, resumable=True)
    req = service.videos().insert(part="snippet,status", body=body, media_body=media)

    resp = None
    while resp is None:
        try:
            _, resp = req.next_chunk()
        except HttpError as e:
            if e.resp.status in (500, 502, 503, 504):
                log(f"retriable HTTP {e.resp.status} on {path.name}, retrying")
                time.sleep(5)
                continue
            raise
    return resp.get("id")


def do_upload():
    """Upload every pending video to YouTube, moving each into an 'uploaded'
    subfolder on success so it isn't re-uploaded."""
    if not YT_ON:
        return {"ok": False, "error": "youtube upload disabled in config.json"}
    if not upload_lock.acquire(blocking=False):
        return {"ok": False, "error": "upload already in progress"}

    uploaded, failed = [], []
    try:
        files = pending_uploads()
        if not files:
            return {"ok": True, "uploaded": [], "failed": [],
                    "note": "nothing to upload"}

        service = get_youtube_service()
        if service is None:
            return {"ok": False, "error": "youtube auth not ready, see the log"}

        dst_dir = uploaded_source_dir() / YT_UPLOADED_SUBDIR
        dst_dir.mkdir(parents=True, exist_ok=True)

        for f in files:
            try:
                vid = upload_one(service, f)
                uploaded.append({"file": f.name, "id": vid})
                log(f"uploaded {f.name} -> https://youtu.be/{vid}")
                try:
                    f.replace(dst_dir / f.name)
                except Exception as e:
                    log(f"uploaded but not moved {f.name}: {e}")
            except Exception:
                failed.append(f.name)
                log(f"ERROR uploading {f.name}:\n" + traceback.format_exc())

        return {"ok": not failed, "uploaded": uploaded, "failed": failed}
    except Exception:
        log("ERROR upload:\n" + traceback.format_exc())
        return {"ok": False, "uploaded": uploaded, "failed": failed,
                "error": "exception, see the log"}
    finally:
        upload_lock.release()


# ---------------------------------------------------------------- HTTP server

class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/status":
            self._send({
                "sf6": running("StreetFighter6.exe"),
                "obs": running("obs64.exe"),
                "watcher": watcher_running(),
                "queue": read_queue(),
                "pending": len(pending_files()),
                "pending_upload": len(pending_uploads()),
                "signature": files_signature(),
            })
        elif self.path == "/diag":
            self._send({
                "config": str(CONFIG_FILE),
                "python_agent": sys.executable,
                "python_watcher": str(PYTHON),
                "python_watcher_exists": PYTHON.exists(),
                "obs": str(OBS),
                "obs_exists": OBS.exists(),
                "watcher": str(WATCHER),
                "watcher_exists": WATCHER.exists(),
                "queue_dir": str(QUEUE.parent),
                "queue_dir_exists": QUEUE.parent.exists(),
                "rec_dir": str(REC_DIR),
                "rec_dir_exists": REC_DIR.exists(),
                "sync_enabled": SYNC_ON,
                "ssh_key": str(SSH_KEY),
                "ssh_key_exists": SSH_KEY.exists(),
                "destination": f"{SSH_DEST}:{DEST_DIR}" if SYNC_ON else "-",
                "youtube_enabled": YT_ON,
                "youtube_token_exists": bool(YT_TOKEN_FILE and YT_TOKEN_FILE.exists()),
                "youtube_privacy": YT_PRIVACY,
            })
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return self._send({"error": "invalid body"}, 400)

        if self.path == "/launch":
            threading.Thread(target=launch_all, daemon=True).start()
            self._send({"ok": True})

        elif self.path == "/queue":
            try:
                self._send({"ok": True, "ids": set_queue(body.get("ids", []))})
            except Exception as e:
                log("ERROR writing queue:\n" + traceback.format_exc())
                self._send({"error": str(e)}, 500)

        elif self.path == "/sync":
            self._send(do_sync())

        elif self.path == "/upload":
            self._send(do_upload())

        elif self.path == "/shutdown":
            log("shutdown requested")
            subprocess.Popen(["shutdown", "/s", "/t", "30"],
                             creationflags=NO_WINDOW)
            self._send({"ok": True})

        else:
            self._send({"error": "not found"}, 404)

    def log_message(self, *args):
        pass  # silence the default HTTP logging


def main():
    log(f"agent listening on {BIND}:{PORT} - interpreter: {sys.executable}")
    if BIND in ("0.0.0.0", ""):
        log("WARNING: bound to all interfaces, the agent is reachable by "
            "anyone on the network. Prefer the VPN address.")
    try:
        HTTPServer((BIND, PORT), Handler).serve_forever()
    except OSError as e:
        log(f"ERROR: cannot listen on {BIND}:{PORT} -> {e}")
        log("Is another agent already running? Close it before relaunching.")
        sys.exit(1)


if __name__ == "__main__":
    main()
