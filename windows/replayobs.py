#!/usr/bin/env python3
"""
replayobs.py - OBS watcher for SF6 Replay Bot.

Reads the trigger files written by recon.lua (in reframework/data) and drives
OBS via obs-websocket: starts recording at match start, stops it at the end,
and renames the file with the players' names and the replay ID.

Safety: if the match exceeds max_seconds, or if the game's heartbeat stops,
the recording is closed anyway.

Configuration in config.json, next to this file (see config.example.json).
It reads the same keys as the agent: use a single config for both.
"""

import json
import re
import time
import pathlib
import sys
import obsws_python as obs

BASE_DIR = pathlib.Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "config.json"


def load_config():
    if not CONFIG_FILE.exists():
        print(f"ERROR: {CONFIG_FILE} is missing")
        print("Copy config.example.json to config.json and fill in the obs and queue_file fields.")
        sys.exit(1)
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"ERROR: config.json is not valid JSON: {e}")
        sys.exit(1)


CFG = load_config()

# the trigger folder is reframework/data, derived from the queue path
# (queue_file), so there is a single path to configure
QUEUE_FILE = pathlib.Path(CFG["queue_file"])
BASE = QUEUE_FILE.parent
TRIG = BASE / "obs_trigger.json"
HB = BASE / "obs_heartbeat.json"

OBS_CFG = CFG.get("obs_websocket", {})
OBS_HOST = OBS_CFG.get("host", "localhost")
OBS_PORT = int(OBS_CFG.get("port", 4455))
OBS_PASSWORD = OBS_CFG.get("password", "")

REC = CFG.get("recording", {})
MAX_SECONDS = int(REC.get("max_seconds", 600))
HB_TIMEOUT = int(REC.get("heartbeat_timeout_sec", 8))
HB_GRACE = int(REC.get("heartbeat_grace_sec", 15))

cl = obs.ReqClient(host=OBS_HOST, port=OBS_PORT, password=OBS_PASSWORD)


def clean(s):
    s = (s or "").strip()
    return re.sub(r'[\\/:*?"<>|]', "_", s) or "unknown"


def hb_age():
    try:
        return time.time() - json.loads(HB.read_text(encoding="utf-8")).get("t", 0)
    except Exception:
        return 9999


last, pending, recording, rec_started = -1, {}, False, 0.0


def do_stop(reason):
    global recording
    if not recording:
        return
    try:
        resp = cl.stop_record()
        src = pathlib.Path(resp.output_path)
        p1, p2 = clean(pending.get("p1")), clean(pending.get("p2"))
        rid = (pending.get("id") or "").strip()
        name = f"{p1} vs {p2} {clean(rid) if rid else int(time.time())}{src.suffix}"
        time.sleep(1.0)
        try:
            dst = src.with_name(name)
            src.rename(dst)
            print(f"saved ({reason}):", dst.name)
        except Exception as e:
            print("rename failed:", e)
    except obs.error.OBSSDKRequestError as e:
        print("stop ignored:", e)
    finally:
        recording = False


# ignore a leftover trigger from the previous session
try:
    if TRIG.exists():
        last = json.loads(TRIG.read_text(encoding="utf-8")).get("seq", -1)
        print("leftover trigger ignored (seq", last, ")")
except Exception:
    pass

print(f"OBS watcher active on {OBS_HOST}:{OBS_PORT}, waiting for triggers from the game...")
print(f"trigger folder: {BASE}")

while True:
    try:
        if recording:
            age = time.time() - rec_started
            if age > MAX_SECONDS:
                do_stop("absolute timeout")
            elif age > HB_GRACE and hb_age() > HB_TIMEOUT:
                do_stop("heartbeat lost")

        if TRIG.exists():
            d = json.loads(TRIG.read_text(encoding="utf-8"))
            if d.get("seq", -1) != last:
                last = d["seq"]
                cmd = d.get("cmd")
                if cmd == "start":
                    pending = d
                    try:
                        cl.start_record()
                        recording = True
                        rec_started = time.time()
                        print("REC start:", d.get("p1"), "vs", d.get("p2"), d.get("id"))
                    except obs.error.OBSSDKRequestError as e:
                        print("start ignored:", e)
                elif cmd == "stop":
                    if recording:
                        do_stop("replay end")
                    else:
                        print("stop ignored (no recording in progress)")
    except Exception:
        pass
    time.sleep(0.4)
