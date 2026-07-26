#!/usr/bin/env python3
"""
yt_auth.py - one-time YouTube OAuth login.

Run this by hand once. It opens the browser, you authorize with the Google
account that owns the target channel, and it saves yt_token.json next to it.
The agent then reuses that token for every upload.

Note: while the OAuth app is in "Testing" mode (i.e. not audited by Google),
the refresh token expires after 7 days, so you'll need to run this again about
once a week. Publishing the app removes that limit but requires Google's audit.

Paths are read from config.json (same file as agent.py / replayobs.py):
  youtube.client_secret  - the JSON downloaded from Google Cloud Console
  youtube.token_file     - where to save the login token
"""

import json
import pathlib
import sys
from google_auth_oauthlib.flow import InstalledAppFlow

BASE_DIR = pathlib.Path(__file__).resolve().parent
CONFIG_FILE = BASE_DIR / "config.json"

SCOPES = ["https://www.googleapis.com/auth/youtube.upload"]


def main():
    if not CONFIG_FILE.exists():
        print(f"ERROR: {CONFIG_FILE} is missing")
        sys.exit(1)
    cfg = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    yt = cfg.get("youtube", {})

    client_secret = pathlib.Path(yt.get("client_secret", "")).expanduser()
    token_file = pathlib.Path(yt.get("token_file", "")).expanduser()

    if not client_secret.exists():
        print(f"ERROR: client secret not found at {client_secret}")
        print("Set youtube.client_secret in config.json to the JSON you downloaded.")
        sys.exit(1)

    print("Opening the browser for authorization...")
    flow = InstalledAppFlow.from_client_secrets_file(str(client_secret), SCOPES)
    creds = flow.run_local_server(port=0)

    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.write_text(creds.to_json(), encoding="utf-8")
    print(f"Done. Token saved to {token_file}")
    print("The agent can now upload. Re-run this if uploads start failing with an "
          "auth error (the testing-mode token expires after ~7 days).")


if __name__ == "__main__":
    main()
