#!/usr/bin/env python3
# bot.py - SF6 replay Telegram bot, runs on the server
import os, socket, asyncio, logging, html, traceback
import httpx
from telegram import Update
from telegram.constants import ParseMode
from telegram.ext import ApplicationBuilder, CommandHandler, ContextTypes

logging.basicConfig(format="%(asctime)s %(levelname)s %(message)s", level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("sf6bot")

TOKEN = os.environ["BOT_TOKEN"]
CHAT_ID = int(os.environ["CHAT_ID"])
AGENT = os.environ["AGENT_URL"].rstrip("/")
MAC = os.environ["PC_MAC"]
BROADCAST = os.environ.get("BROADCAST", "255.255.255.255")
STABLE_SEC = 90       # how long files must stay unchanged before syncing
POLL_SEC = 15
MAX_WAIT = 3600       # max one hour of waiting for the queue


# ---------- helpers ----------

def wol(mac: str, broadcast: str) -> None:
    mac = mac.replace(":", "").replace("-", "").replace(".", "")
    if len(mac) != 12:
        raise ValueError(f"invalid MAC: {mac}")
    packet = b"\xff" * 6 + bytes.fromhex(mac) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.sendto(packet, (broadcast, 9))
    s.close()


def queue_ids(status: dict) -> list:
    if not isinstance(status, dict):
        return []
    q = status.get("queue")
    if isinstance(q, list):
        return [str(i) for i in q]
    if not isinstance(q, dict):
        return []
    ids = q.get("ids")
    if not isinstance(ids, list):
        return []
    return [str(i) for i in ids]


async def agent_get(path: str, timeout: float = 5.0):
    async with httpx.AsyncClient(timeout=timeout) as c:
        r = await c.get(f"{AGENT}{path}")
        r.raise_for_status()
        return r.json()


async def agent_post(path: str, payload: dict | None = None, timeout: float = 10.0):
    async with httpx.AsyncClient(timeout=timeout) as c:
        r = await c.post(f"{AGENT}{path}", json=payload or {})
        r.raise_for_status()
        return r.json()


async def agent_alive(timeout: float = 3.0) -> bool:
    try:
        await agent_get("/status", timeout=timeout)
        return True
    except Exception:
        return False


def authorized(update: Update) -> bool:
    return update.effective_chat and update.effective_chat.id == CHAT_ID


def deny_log(update: Update) -> None:
    cid = update.effective_chat.id if update.effective_chat else "?"
    log.warning("access denied from chat_id %s", cid)


def format_upload(up: dict) -> str:
    """Turn the agent's /upload response into a readable Telegram message."""
    if up.get("error"):
        return f"YouTube upload failed: {up['error']}"
    uploaded = up.get("uploaded", [])
    failed = up.get("failed", [])
    if not uploaded and not failed:
        return up.get("note", "Nothing to upload.")
    lines = [f"Uploaded {len(uploaded)} video(s) to YouTube:"]
    for u in uploaded:
        lines.append(f"- {u['file']}: https://youtu.be/{u['id']}")
    if failed:
        lines.append(f"Failed: {', '.join(failed)} (see the agent log)")
    return "\n".join(lines)


# ---------- end-of-queue watcher ----------

async def watch_and_upload(ctx: ContextTypes.DEFAULT_TYPE):
    """Wait for the queue to empty and the files to stop changing,
    then upload to YouTube and notify."""
    try:
        deadline = asyncio.get_event_loop().time() + MAX_WAIT
        signature, stable_for = None, 0.0

        while asyncio.get_event_loop().time() < deadline:
            await asyncio.sleep(POLL_SEC)
            try:
                st = await agent_get("/status")
            except Exception:
                continue        # PC momentarily unreachable, retry

            new = st.get("signature", {})
            if new == signature:
                stable_for += POLL_SEC
            else:
                signature, stable_for = new, 0.0

            queue_empty = not queue_ids(st)
            if queue_empty and stable_for >= STABLE_SEC and st.get("pending_upload", 0) > 0:
                break
        else:
            return await ctx.bot.send_message(
                CHAT_ID, "Timeout: the queue didn't clear within an hour. "
                         "Use /upload manually whenever you want."
            )

        await ctx.bot.send_message(CHAT_ID, "Recordings done, uploading to YouTube...")
        up = await agent_post("/upload", timeout=3600)
        await ctx.bot.send_message(CHAT_ID, format_upload(up))

    except Exception:
        log.error("error in the watcher", exc_info=True)
        await ctx.bot.send_message(CHAT_ID, "Error during upload, check the logs.")


# ---------- commands ----------

async def cmd_start(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)
    await update.message.reply_text(
        "*SF6 replay bot*\n\n"
        "/on - wake the PC and launch OBS, watcher and SF6\n"
        "/rec ID [ID ...] - add replays to the queue\n"
        "/queue - show the current queue\n"
        "/status - PC and process status\n"
        "/upload - upload the videos to YouTube now\n"
        "/diag - paths configured on the agent\n"
        "/off - shut down the PC (30s grace)\n",
        parse_mode=ParseMode.MARKDOWN,
    )


async def cmd_on(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)

    if await agent_alive():
        await update.message.reply_text("PC is already on. Launching the programs...")
    else:
        try:
            wol(MAC, BROADCAST)
        except Exception as e:
            return await update.message.reply_text(f"Error sending the magic packet: {e}")
        msg = await update.message.reply_text("Magic packet sent, waiting for boot...")
        for i in range(36):
            await asyncio.sleep(5)
            if await agent_alive():
                await msg.edit_text(f"PC up after about {(i + 1) * 5}s. Launching the programs...")
                break
        else:
            return await msg.edit_text(
                "The PC didn't respond within 3 minutes.\n"
                "Check WoL in the BIOS, autologin, and that the agent starts at login."
            )

    try:
        await agent_post("/launch")
    except Exception as e:
        return await update.message.reply_text(f"The agent rejected /launch: {e}")

    await update.message.reply_text("Starting up: OBS, watcher and SF6. Checking in a minute...")
    await asyncio.sleep(60)
    try:
        st = await agent_get("/status")
        await update.message.reply_text(
            "Status after startup:\n"
            f"SF6: {'ok' if st.get('sf6') else 'NOT started'}\n"
            f"OBS: {'ok' if st.get('obs') else 'NOT started'}\n"
            f"watcher: {'ok' if st.get('watcher') else 'NOT started'}"
        )
    except Exception as e:
        await update.message.reply_text(f"Can't read the status: {e}")


async def cmd_rec(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)

    ids = [a.strip() for a in ctx.args if a.strip()]
    if not ids:
        return await update.message.reply_text(
            "Usage: /rec ID [ID ...]\nExample: /rec ABCD1234 EFGH5678"
        )

    try:
        res = await agent_post("/queue", {"ids": ids})
    except Exception as e:
        return await update.message.reply_text(
            f"Can't write the queue: {e}\nIs the PC on? Try /on."
        )

    written = res.get("ids") or ids
    await update.message.reply_text(
        "Queue written ({} replay(s)):\n{}\n\n"
        "I'll let you know when they're uploaded to YouTube.".format(
            len(written), "\n".join(f"- {i}" for i in written)
        )
    )
    asyncio.create_task(watch_and_upload(ctx))


async def cmd_upload(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)
    await update.message.reply_text("Uploading to YouTube, this may take a while...")
    try:
        up = await agent_post("/upload", timeout=3600)
    except Exception as e:
        return await update.message.reply_text(f"Upload failed: {e}")
    await update.message.reply_text(format_upload(up))


async def cmd_queue(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)
    try:
        st = await agent_get("/status")
    except Exception as e:
        return await update.message.reply_text(f"PC unreachable: {e}")
    ids = queue_ids(st)
    if not ids:
        return await update.message.reply_text("The queue is empty.")
    await update.message.reply_text(
        "In queue ({}):\n{}".format(len(ids), "\n".join(f"- {i}" for i in ids))
    )


async def cmd_status(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)
    try:
        st = await agent_get("/status")
    except Exception as e:
        return await update.message.reply_text(
            f"PC unreachable ({e}).\nIt's probably off: /on to wake it."
        )
    await update.message.reply_text(
        "PC: on\n"
        f"SF6: {'running' if st.get('sf6') else 'stopped'}\n"
        f"OBS: {'running' if st.get('obs') else 'stopped'}\n"
        f"watcher: {'running' if st.get('watcher') else 'stopped'}\n"
        f"Queue: {len(queue_ids(st))} replay(s)\n"
        f"Videos to upload: {st.get('pending_upload', 0)}"
    )


async def cmd_diag(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)
    try:
        d = await agent_get("/diag")
    except Exception as e:
        return await update.message.reply_text(f"PC unreachable: {e}")
    await update.message.reply_text("\n".join(f"{k}: {v}" for k, v in d.items()))


async def cmd_off(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    if not authorized(update):
        return deny_log(update)
    try:
        await agent_post("/shutdown")
        await update.message.reply_text("Shutdown started (30 seconds).")
    except Exception as e:
        await update.message.reply_text(f"Can't shut down: {e}")


# ---------- error handling ----------

async def on_error(update: object, ctx: ContextTypes.DEFAULT_TYPE):
    log.error("unhandled exception", exc_info=ctx.error)
    tb = "".join(traceback.format_exception(None, ctx.error, ctx.error.__traceback__))
    try:
        await ctx.bot.send_message(
            CHAT_ID, f"<b>Bot error</b>\n<pre>{html.escape(tb[-1200:])}</pre>",
            parse_mode=ParseMode.HTML,
        )
    except Exception:
        pass


def main():
    app = ApplicationBuilder().token(TOKEN).concurrent_updates(True).build()
    for name, fn in [("start", cmd_start), ("help", cmd_start), ("on", cmd_on),
                     ("rec", cmd_rec), ("queue", cmd_queue), ("status", cmd_status),
                     ("upload", cmd_upload), ("diag", cmd_diag), ("off", cmd_off)]:
        app.add_handler(CommandHandler(name, fn))
    app.add_error_handler(on_error)
    log.info("bot started")
    app.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == "__main__":
    main()
