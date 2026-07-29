# 🎥 sf6-replay-bot-youtube - Record and upload Street Fighter replays

[![](https://img.shields.io/badge/Download-Releases-blue.svg)](https://github.com/vedantg7334/sf6-replay-bot-youtube/releases)

This software records Street Fighter 6 replays and moves them to your YouTube channel. You control the process through Telegram. Send a replay ID to the bot, and the program handles the rest. It starts the game, records the match, and uploads the video file.

## ⚙️ System Requirements

Your computer needs specific parts to run this tool well.

- Windows 10 or 11 (64-bit).
- At least 8GB of RAM.
- A stable internet connection for game recording and YouTube uploads.
- OBS Studio installed for screen capture.
- A Google account with YouTube Data API enabled.
- REFramework installed in your game folder.

## 📥 How to Download 

Visit the official website to download the latest setup file. Pick the file ending in .zip or .exe from the assets list.

[Download the software here](https://github.com/vedantg7334/sf6-replay-bot-youtube/releases)

Save the file to a folder on your computer. Extract the contents if you downloaded a zip folder. Do not run the file yet. You must configure the program first.

## 🛠️ Initial Setup

This tool requires small adjustments to connect to your YouTube and Telegram accounts. You must find your API keys first. 

1. Create a project in the Google Cloud Console.
2. Enable the YouTube Data API v3.
3. Generate credentials for a service account or an OAuth client.
4. Save the JSON key file in the program folder. Rename it to `credentials.json` if necessary.

You also need a Telegram bot token.

1. Open Telegram and search for "BotFather".
2. Send the message `/newbot` to start the process.
3. Follow the instructions to name your bot.
4. Copy the API token provided by BotFather.
5. Paste this token into the configuration file of this software.

## 🚀 Running the Bot

Follow these steps to start the automation.

1. Open your game, Street Fighter 6.
2. Launch the robot file from the folder where you saved it.
3. A black command window appears on your screen. This window shows the status of your requests.
4. Open Telegram on your phone or your computer.
5. Send the replay ID to your new bot.

The program detects the ID. It switches to the game window, navigates to the replay menu, enters the ID, and begins recording.

## 📼 Recording and Uploading

The bot uses OBS Studio to record the match. Ensure that OBS Studio is open and configured to record to a folder that the bot can access. 

The bot names your file using the format: PlayerA vs PlayerB - [ReplayID].mp4. Once the match ends, the bot stops the recording. It then connects to your YouTube account and uploads the file. You receive a confirmation message in Telegram when the upload finishes.

## 🔧 Troubleshooting Common Issues

If the bot fails, check these items.

- Game Overlay: Disable any other overlays like Steam or Discord while the bot runs.
- Screen Resolution: Keep your game resolution at 1920x1080 for best results with the automation.
- API Limits: Google limits how many videos you can upload per day. If you hit this limit, the bot will notify you in the command window.
- OBS Settings: Ensure OBS is set to output in a standard format like .mp4 or .mkv.
- File Paths: Keep the program folder in a location where Windows has permission to create and delete files. Avoid "Program Files" if you experience permission errors.

## 🛡️ Security Notes

Your API keys provide access to your accounts. Do not share the `credentials.json` file or your Telegram token with others. Store these files securely. If you suspect someone else has these keys, revoke them in the Google Cloud Console and generate new ones.

Keywords: fgc, game-automation, lua, obs-studio, python, reframework, replay, street-fighter-6, telegram-bot, youtube-api, youtube-api-v3