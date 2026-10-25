#!/bin/bash
set -e

INSTALL_DIR="/opt/leechbot"
CONFIG_FILE="$INSTALL_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/leechbot.service"
CLI_BIN="/usr/local/bin/leech-bot"

clear
echo "=========================================================="
echo " 🚀 All-in-One Telegram Leech, Unzip & Media Bot Installer"
echo "=========================================================="

if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this installer as root (sudo bash install.sh)."
    exit 1
fi

mkdir -p "$INSTALL_DIR/downloads" "$INSTALL_DIR/user_cookies"

# Detect default network interface (e.g., eth0)
DEFAULT_IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
DEFAULT_IFACE=${DEFAULT_IFACE:-eth0}

# 1. Interactive Configuration (if config.json does not exist or user wants to reconfigure)
USE_EXISTING="n"
if [ -f "$CONFIG_FILE" ]; then
    read -rp "⚙️  Existing config.json found. Keep current credentials? [Y/n]: " USE_EXISTING
    USE_EXISTING=${USE_EXISTING:-Y}
fi

if [[ ! "$USE_EXISTING" =~ ^[Yy]$ ]]; then
    echo ""
    echo "🔑 Please enter your Telegram Credentials (from my.telegram.org & @BotFather):"
    read -rp "👉 Enter APP API_ID: " INPUT_API_ID
    read -rp "👉 Enter API_HASH: " INPUT_API_HASH
    read -rp "👉 Enter BOT_TOKEN: " INPUT_BOT_TOKEN
    read -rp "👉 Enter ADMIN_IDS (space-separated, e.g. 1551433194 5190391120): " INPUT_ADMINS
    read -rp "👉 Enter Private Dump Group ID (optional, press Enter to skip & use /setgroup later): " INPUT_DUMP_GROUP

    # Format admin IDs into JSON array
    ADMIN_JSON=$(echo "$INPUT_ADMINS" | tr ',' ' ' | awk '{
        printf "[";
        for(i=1;i<=NF;i++) {
            printf "%s%s", $i, (i<NF ? ", " : "");
        }
        printf "]";
    }')

    if [ -z "$INPUT_DUMP_GROUP" ]; then
        DUMP_JSON="null"
    else
        DUMP_JSON="$INPUT_DUMP_GROUP"
    fi

    cat << CONFIG_EOF > "$CONFIG_FILE"
{
    "api_id": $INPUT_API_ID,
    "api_hash": "$INPUT_API_HASH",
    "bot_token": "$INPUT_BOT_TOKEN",
    "admin_ids": $ADMIN_JSON,
    "dump_chat_id": $DUMP_JSON,
    "banned_users": [],
    "interface": "$DEFAULT_IFACE"
}
CONFIG_EOF
    chmod 600 "$CONFIG_FILE"
    echo "✅ Configuration saved to $CONFIG_FILE"
fi

echo ""
echo "=========================================================="
echo " 📦 Installing System Dependencies & Python 3.11+..."
echo "=========================================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y software-properties-common curl git build-essential \
    ffmpeg p7zip-full unrar unzip tar xz-utils bzip2 vnstat aria2 nodejs

# Ensure Python 3.11+ is available (fixes yt-dlp Python 3.10 deprecation on Ubuntu 22.04)
if ! command -v python3.11 &>/dev/null; then
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update -y
    apt-get install -y python3.11 python3.11-venv python3.11-dev
fi

echo "=========================================================="
echo " 🌐 Configuring Persistent vnStat on $DEFAULT_IFACE..."
echo "=========================================================="
sed -i 's/;SaveInterval 5/SaveInterval 1/g' /etc/vnstat.conf 2>/dev/null || true
sed -i 's/SaveInterval 5/SaveInterval 1/g' /etc/vnstat.conf 2>/dev/null || true
vnstat --add -i "$DEFAULT_IFACE" 2>/dev/null || true
systemctl enable vnstat
systemctl restart vnstat

echo "=========================================================="
echo " 🐍 Building Python Virtual Environment & Installing yt-dlp..."
echo "=========================================================="
cd "$INSTALL_DIR"
if [ ! -f "$INSTALL_DIR/venv/bin/python3.11" ]; then
    rm -rf "$INSTALL_DIR/venv"
    python3.11 -m venv venv
fi
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install --upgrade telethon cryptg psutil aiohttp
"$INSTALL_DIR/venv/bin/pip" install -U --pre "yt-dlp[default,curl-cffi]"

echo "=========================================================="
echo " 🤖 Deploying Bot Application ($INSTALL_DIR/bot.py)..."
echo "=========================================================="
cat << 'PY_EOF' > "$INSTALL_DIR/bot.py"
import os
import re
import time
import math
import json
import shutil
import asyncio
import logging
import urllib.parse
import subprocess
from pathlib import Path

import psutil
import aiohttp
import yt_dlp
from telethon import TelegramClient, events, Button
from telethon.tl.types import DocumentAttributeVideo, DocumentAttributeFilename

BASE_DIR = Path("/opt/leechbot")
DOWNLOAD_DIR = str(BASE_DIR / "downloads")
CONFIG_FILE = BASE_DIR / "config.json"
COOKIES_DIR = BASE_DIR / "user_cookies"
GLOBAL_COOKIES = BASE_DIR / "cookies.txt"

shutil.rmtree(DOWNLOAD_DIR, ignore_errors=True)
os.makedirs(DOWNLOAD_DIR, exist_ok=True)
COOKIES_DIR.mkdir(parents=True, exist_ok=True)

MAX_STORAGE_POOL = 20 * 1024 * 1024 * 1024        # 20 GB workspace cap
MIN_OS_FREE_SPACE = int(1.5 * 1024 * 1024 * 1024) # 1.5 GB OS safety buffer
NORMAL_USER_LIMIT = 4 * 1024 * 1024 * 1024        # 4 GB limit for normal users
MAX_SPLIT_BYTES = 1900 * 1024 * 1024              # 1.9 GB split threshold

VIDEO_EXTS = {".mp4", ".mkv", ".avi", ".mov", ".webm"}
ARCHIVE_EXTS = (
    ".zip", ".rar", ".7z", ".tar", ".gz", ".tgz", ".bz2",
    ".tbz2", ".xz", ".txz", ".iso", ".cab", ".arj", ".z"
)

def load_config():
    with open(CONFIG_FILE, "r") as f:
        data = json.load(f)
    data.setdefault("banned_users", [])
    data.setdefault("dump_chat_id", None)
    data.setdefault("interface", "eth0")
    return data

def save_config(cfg_data):
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg_data, f, indent=4)

CONFIG = load_config()
API_ID = int(CONFIG["api_id"])
API_HASH = CONFIG["api_hash"]
BOT_TOKEN = CONFIG["bot_token"]
AUTHORIZED_ADMINS = set(CONFIG["admin_ids"])
INTERFACE = CONFIG.get("interface", "eth0")

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")

loop = asyncio.new_event_loop()
asyncio.set_event_loop(loop)
bot = TelegramClient(str(BASE_DIR / "bot_session"), API_ID, API_HASH, loop=loop)

ACTIVE_JOBS = {}        # jid -> {"user_id": int, "url": str, "cancelled": bool, "task": Task, "desc": str}
PENDING_ARCHIVES = {}   # jid -> {"msg": Message, "user_id": int}
WAITING_PASS = {}       # user_id -> {"jid": str, "prompt_msg": Message}

class JobCancelledError(Exception):
    pass

def is_admin(uid: int) -> bool:
    return uid in set(load_config().get("admin_ids", [])) or uid in AUTHORIZED_ADMINS

def is_banned(uid: int) -> bool:
    return uid in set(load_config().get("banned_users", []))

def user_has_active_job(uid: int) -> bool:
    if is_admin(uid):
        return False  # Admins have unlimited parallel tasks
    return any(
        job.get("user_id") == uid and not job.get("cancelled") and job.get("task") is not None
        for job in ACTIVE_JOBS.values()
    )

def fmt_size(b: float) -> str:
    if b <= 0:
        return "0.00 B"
    for u in ["B", "KB", "MB", "GB", "TB"]:
        if b < 1024.0:
            return f"{b:.2f} {u}"
        b /= 1024.0
    return f"{b:.2f} PB"

def progress_bar(curr: float, tot: float, length: int = 10) -> str:
    if tot <= 0:
        return "░" * length
    filled = max(0, min(length, int(round((curr / tot) * length))))
    return "█" * filled + "░" * (length - filled)

def get_dir_size(path_str: str) -> int:
    total = 0
    if not os.path.exists(path_str):
        return 0
    for root, _, files in os.walk(path_str):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total

def get_available_pool_bytes() -> int:
    used_pool = get_dir_size(DOWNLOAD_DIR)
    pool_rem = max(0, MAX_STORAGE_POOL - used_pool)
    os_free = max(0, shutil.disk_usage("/").free - MIN_OS_FREE_SPACE)
    return min(pool_rem, os_free)

def has_storage_space(required_bytes: int = 100 * 1024 * 1024) -> bool:
    return get_available_pool_bytes() >= required_bytes

def get_user_cookie_path(uid: int):
    user_p = COOKIES_DIR / f"{uid}.txt"
    if user_p.exists() and user_p.stat().st_size > 0:
        return str(user_p)
    if GLOBAL_COOKIES.exists() and GLOBAL_COOKIES.stat().st_size > 0:
        return str(GLOBAL_COOKIES)
    return None

def cookies_status(uid: int) -> str:
    user_p = COOKIES_DIR / f"{uid}.txt"
    if user_p.exists() and user_p.stat().st_size > 0:
        return f"Loaded ✅ ({fmt_size(user_p.stat().st_size)})"
    if is_admin(uid) and GLOBAL_COOKIES.exists() and GLOBAL_COOKIES.stat().st_size > 0:
        return f"Global Loaded ✅ ({fmt_size(GLOBAL_COOKIES.stat().st_size)})"
    return "Not Set ❌"

def cancel_btn(jid: str):
    return [[Button.inline("❌ Cancel Operation", f"cancel:{jid}".encode())]]

def quality_btns(jid: str, direct_only: bool = False):
    if direct_only:
        return [
            [Button.inline("📦 Direct File Download", f"q:direct:{jid}".encode())],
            [Button.inline("📂 Direct Download + Auto-Unzip", f"q:direct_unzip:{jid}".encode())],
            [Button.inline("❌ Cancel", f"cancel:{jid}".encode())]
        ]
    return [
        [
            Button.inline("🎬 1080p", f"q:1080:{jid}".encode()),
            Button.inline("🎬 720p", f"q:720:{jid}".encode()),
            Button.inline("🎬 480p", f"q:480:{jid}".encode()),
        ],
        [
            Button.inline("🎬 360p", f"q:360:{jid}".encode()),
            Button.inline("🎵 MP3 Audio", f"q:mp3:{jid}".encode()),
        ],
        [
            Button.inline("📦 Direct File Download", f"q:direct:{jid}".encode())
        ],
        [
            Button.inline("📂 Direct Download + Auto-Unzip", f"q:direct_unzip:{jid}".encode())
        ],
        [
            Button.inline("❌ Cancel", f"cancel:{jid}".encode())
        ]
    ]

def is_cancelled(jid: str) -> bool:
    return bool(ACTIVE_JOBS.get(jid, {}).get("cancelled"))

def is_archive_name(fname: str) -> bool:
    lower = fname.lower()
    return any(lower.endswith(ext) for ext in ARCHIVE_EXTS)

def format_user_tag(sender) -> str:
    if not sender:
        return "👤 **User:** `Unknown`"
    first = getattr(sender, "first_name", "") or ""
    last = getattr(sender, "last_name", "") or ""
    full_name = f"{first} {last}".strip() or "No Name"
    uname = f"@{sender.username}" if getattr(sender, "username", None) else "None"
    uid = sender.id
    return (
        f"👤 **Name:** [{full_name}](tg://user?id={uid})\n"
        f"🔗 **Username:** {uname}\n"
        f"🆔 **Telegram ID:** `{uid}`"
    )

async def forward_to_dump_group(message_obj, sender, action_label: str):
    dump_id = load_config().get("dump_chat_id")
    if not dump_id or not message_obj:
        return
    try:
        tag_text = (
            f"📥 **User Activity Logged**\n"
            f"🏷️ **Task:** `{action_label}`\n"
            f"{format_user_tag(sender)}"
        )
        fwd = await bot.forward_messages(int(dump_id), message_obj)
        target_msg = fwd[0] if isinstance(fwd, list) else fwd
        await bot.send_message(int(dump_id), tag_text, reply_to=target_msg.id)
    except Exception as e:
        logging.warning(f"Dump group forward error: {e}")

def clean_empty_files(out_dir: str):
    for root, _, fnames in os.walk(out_dir):
        for f in fnames:
            p = os.path.join(root, f)
            try:
                if os.path.isfile(p) and os.path.getsize(p) == 0:
                    os.remove(p)
            except OSError:
                pass

def extract_archive_sync(archive_path: str, out_dir: str, password: str = "") -> tuple[bool, str]:
    lower = archive_path.lower()
    os.makedirs(out_dir, exist_ok=True)

    if lower.endswith((".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz")):
        res = subprocess.run(["tar", "-xf", archive_path, "-C", out_dir], capture_output=True, text=True)
        if res.returncode == 0:
            return True, ""

    if lower.endswith(".rar"):
        pw_flag = f"-p{password}" if password else "-p-"
        res = subprocess.run(["unrar", "x", "-y", pw_flag, archive_path, f"{out_dir}/"], capture_output=True, text=True)
        if res.returncode == 0:
            return True, ""
        clean_empty_files(out_dir)

    pw_arg = f"-p{password}" if password else "-p-"
    res = subprocess.run(["7z", "x", "-y", pw_arg, f"-o{out_dir}", archive_path], capture_output=True, text=True)
    if res.returncode == 0:
        return True, ""
    clean_empty_files(out_dir)

    pw_flag = f"-p{password}" if password else "-p-"
    res_rar = subprocess.run(["unrar", "x", "-y", pw_flag, archive_path, f"{out_dir}/"], capture_output=True, text=True)
    if res_rar.returncode == 0:
        return True, ""
    clean_empty_files(out_dir)

    return False, (res.stderr or res.stdout or "Wrong password or unsupported/corrupted archive").strip()[-350:]

def get_video_meta(path: str):
    try:
        cmd = [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height:format=duration", "-of", "json", path
        ]
        data = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
        s = data.get("streams", [{}])[0]
        dur = int(float(data.get("format", {}).get("duration", 0)))
        return dur, int(s.get("width", 1280)), int(s.get("height", 720))
    except Exception:
        return 0, 1280, 720

def make_thumb(vpath: str, tpath: str):
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-ss", "00:00:03", "-i", vpath, "-vframes", "1", "-q:v", "4", tpath],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True
        )
        return tpath if (os.path.exists(tpath) and os.path.getsize(tpath) > 0) else None
    except Exception:
        return None

def split_file(fpath: str, wdir: str) -> list:
    fsize = os.path.getsize(fpath)
    if fsize <= MAX_SPLIT_BYTES:
        return [fpath]
    bname = os.path.basename(fpath)
    root, ext = os.path.splitext(bname)
    if ext.lower() in VIDEO_EXTS:
        dur, _, _ = get_video_meta(fpath)
        if dur > 0:
            seg = max(60, int(dur / math.ceil(fsize / MAX_SPLIT_BYTES)))
            pat = os.path.join(wdir, f"{root}.part%03d{ext}")
            res = subprocess.run(
                ["ffmpeg", "-y", "-i", fpath, "-c", "copy", "-map", "0",
                 "-f", "segment", "-segment_time", str(seg), "-reset_timestamps", "1", pat],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if res.returncode == 0:
                os.remove(fpath)
                parts = sorted(
                    os.path.join(wdir, f) for f in os.listdir(wdir)
                    if f.startswith(f"{root}.part") and os.path.getsize(os.path.join(wdir, f)) > 0
                )
                if parts:
                    return parts
    pref = os.path.join(wdir, f"{bname}.part_")
    subprocess.run(["split", "-b", f"{MAX_SPLIT_BYTES}", "-d", "-a", "3", fpath, pref], check=True)
    os.remove(fpath)
    return sorted(
        os.path.join(wdir, f) for f in os.listdir(wdir)
        if f.startswith(f"{bname}.part_") and os.path.getsize(os.path.join(wdir, f)) > 0
    )

async def is_direct_link(url: str) -> bool:
    clean_path = url.split("?")[0].lower()
    direct_exts = VIDEO_EXTS | set(ARCHIVE_EXTS) | {".mp3", ".m4a", ".flac", ".pdf", ".apk", ".exe", ".bin", ".dmg"}
    if any(clean_path.endswith(ext) for ext in direct_exts):
        return True
    hdrs = {"User-Agent": "Mozilla/5.0"}
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=12), headers=hdrs) as s:
            async with s.get(url, allow_redirects=True) as r:
                if r.status >= 400:
                    return False
                ct = r.headers.get("Content-Type", "").lower()
                cd = r.headers.get("Content-Disposition", "").lower()
                return True if "attachment" in cd else not ("text/html" in ct or "text/plain" in ct)
    except Exception:
        return False

async def download_direct(url: str, folder: str, msg, jid: str, max_bytes: int) -> str:
    hdrs = {"User-Agent": "Mozilla/5.0"}
    timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=120)
    async with aiohttp.ClientSession(timeout=timeout, headers=hdrs) as s:
        async with s.get(url, allow_redirects=True) as r:
            r.raise_for_status()
            raw_name = os.path.basename(urllib.parse.unquote(urllib.parse.urlparse(str(r.url)).path))
            fname = re.sub(r'[\\/*?:"<>|]', "_", raw_name).strip(" .") or f"file_{jid}.bin"
            fpath = os.path.join(folder, fname)
            tot = int(r.headers.get("Content-Length", 0))

            if max_bytes > 0 and tot > max_bytes:
                raise ValueError(f"File size ({fmt_size(tot)}) exceeds your 4.00 GB limit!")
            if tot > get_available_pool_bytes():
                raise RuntimeError("Not enough space in the 20 GB server pool! Please wait for current tasks to finish.")

            dl, t0, last = 0, time.time(), 0.0
            with open(fpath, "wb") as f:
                async for chunk in r.content.iter_chunked(1024 * 1024):
                    if is_cancelled(jid):
                        raise JobCancelledError()
                    dl += len(chunk)
                    if max_bytes > 0 and dl > max_bytes:
                        raise ValueError("Download exceeded your 4.00 GB limit!")
                    if not has_storage_space(50 * 1024 * 1024):
                        raise RuntimeError("Server reached the 20 GB storage limit!")
                    f.write(chunk)
                    now = time.time()
                    if now - last >= 3:
                        spd = dl / max(0.1, now - t0)
                        pct = (dl / tot * 100) if tot else 0
                        try:
                            await msg.edit(
                                f"⬇ **Downloading Direct File...**\n📄 `{fname}`\n"
                                f"`[{progress_bar(dl, tot)}] {pct:.1f}%`\n"
                                f"💾 `{fmt_size(dl)} / {fmt_size(tot) if tot else 'Unknown'}` • ⚡ `{fmt_size(spd)}/s`",
                                buttons=cancel_btn(jid)
                            )
                        except Exception:
                            pass
                        last = now
            return fpath

def download_ytdlp(url: str, qual: str, folder: str, msg, jid: str, uid: int, max_bytes: int, main_loop) -> str:
    last = [0.0]

    def hook(d):
        if is_cancelled(jid):
            raise yt_dlp.utils.DownloadError("JOB_CANCELLED")
        if d.get("status") == "downloading":
            dl = d.get("downloaded_bytes", 0)
            tot = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            if max_bytes > 0 and dl > max_bytes:
                raise yt_dlp.utils.DownloadError("LIMIT_EXCEEDED: File exceeds 4 GB limit.")
            if not has_storage_space(50 * 1024 * 1024):
                raise yt_dlp.utils.DownloadError("STORAGE_FULL: Server 20 GB storage limit reached.")
            now = time.time()
            if now - last[0] >= 3:
                spd = d.get("speed") or 0
                pct = (dl / tot * 100) if tot else 0
                txt = (
                    f"🎬 **Downloading ({qual.upper()})...**\n"
                    f"`[{progress_bar(dl, tot)}] {pct:.1f}%`\n"
                    f"💾 `{fmt_size(dl)} / {fmt_size(tot) if tot else 'Unknown'}` • ⚡ `{fmt_size(spd)}/s`"
                )
                asyncio.run_coroutine_threadsafe(msg.edit(txt, buttons=cancel_btn(jid)), main_loop)
                last[0] = now

    opts = {
        "outtmpl": os.path.join(folder, "%(id)s_%(title).80s.%(ext)s"),
        "restrictfilenames": True,
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "progress_hooks": [hook],
    }

    cookie_file = get_user_cookie_path(uid)
    if cookie_file:
        opts["cookiefile"] = cookie_file

    if qual == "mp3":
        opts["format"] = "bestaudio/best"
        opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3", "preferredquality": "192"}]
    else:
        # Flexible format string with codec-agnostic fallback + mp4 merge
        opts["format"] = (
            f"bestvideo[height<={qual}]+bestaudio/"
            f"best[height<={qual}]/bestvideo+bestaudio/best"
        )
        opts["merge_output_format"] = "mp4"

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.extract_info(url, download=True)
    except Exception as e:
        if is_cancelled(jid) or "JOB_CANCELLED" in str(e):
            raise JobCancelledError()
        raise

    files = [
        os.path.join(folder, f) for f in os.listdir(folder)
        if os.path.isfile(os.path.join(folder, f))
        and not f.endswith((".part", ".ytdl", ".jpg", ".webp", ".png"))
        and os.path.getsize(os.path.join(folder, f)) > 0
    ]
    if not files:
        raise RuntimeError("No valid media file was produced.")
    best_file = max(files, key=os.path.getsize)
    if max_bytes > 0 and os.path.getsize(best_file) > max_bytes:
        raise ValueError("Downloaded media exceeds your 4.00 GB limit!")
    return best_file

async def upload_file_list(chat_id: int, sender, files: list, base_dir: str, msg, jid: str, action_label: str):
    valid_files = [f for f in files if os.path.exists(f) and os.path.getsize(f) > 0]
    if not valid_files:
        raise RuntimeError("Extracted/downloaded files are empty (0 bytes).")

    tot_f = len(valid_files)
    for idx, fpath in enumerate(valid_files, 1):
        if is_cancelled(jid):
            raise JobCancelledError()
        if not os.path.exists(fpath) or os.path.getsize(fpath) == 0:
            continue

        rel_name = os.path.relpath(fpath, base_dir)
        fsize = os.path.getsize(fpath)
        if fsize > MAX_SPLIT_BYTES:
            await msg.edit(f"✂️ **Splitting `{rel_name}` ({fmt_size(fsize)})...**", buttons=cancel_btn(jid))
            parts = await asyncio.to_thread(split_file, fpath, os.path.dirname(fpath))
        else:
            parts = [fpath]

        tot_p = len(parts)
        for p_idx, ppath in enumerate(parts, 1):
            if is_cancelled(jid):
                raise JobCancelledError()
            if not os.path.exists(ppath) or os.path.getsize(ppath) == 0:
                continue

            pname = os.path.basename(ppath)
            psize = os.path.getsize(ppath)
            ext = os.path.splitext(pname)[1].lower()

            attrs, thumb = [], None
            if ext in VIDEO_EXTS:
                d, w, h = await asyncio.to_thread(get_video_meta, ppath)
                attrs.append(DocumentAttributeVideo(duration=d, w=w, h=h, supports_streaming=True))
                thumb = await asyncio.to_thread(make_thumb, ppath, os.path.join(os.path.dirname(ppath), f"th_{idx}_{p_idx}.jpg"))

            up_t0, up_last = time.time(), [0.0]

            async def up_cb(curr, tot):
                if is_cancelled(jid):
                    raise JobCancelledError()
                now = time.time()
                if now - up_last[0] >= 3:
                    spd = curr / max(0.1, now - up_t0)
                    pct = (curr / tot * 100) if tot else 0
                    try:
                        await msg.edit(
                            f"⬆ **Uploading File {idx}/{tot_f} (Part {p_idx}/{tot_p})...**\n📄 `{pname}`\n"
                            f"`[{progress_bar(curr, tot)}] {pct:.1f}%`\n"
                            f"💾 `{fmt_size(curr)} / {fmt_size(tot)}` • ⚡ `{fmt_size(spd)}/s`",
                            buttons=cancel_btn(jid)
                        )
                    except Exception:
                        pass
                    up_last[0] = now

            part_tag = f" (Part {p_idx}/{tot_p})" if tot_p > 1 else ""
            sent_msg = await bot.send_file(
                chat_id,
                file=ppath,
                thumb=thumb,
                attributes=attrs,
                supports_streaming=(ext in VIDEO_EXTS),
                progress_callback=up_cb,
                caption=f"📄 **`{pname}`**{part_tag}\n📦 File `{idx}/{tot_f}` • `{fmt_size(psize)}`"
            )
            await forward_to_dump_group(sent_msg, sender, f"{action_label} [{idx}/{tot_f}]")

            if thumb and os.path.exists(thumb):
                os.remove(thumb)
            if os.path.exists(ppath):
                os.remove(ppath)

async def run_link_job(chat_id: int, sender, msg, jid: str, mode: str, qual: str = "1080"):
    info = ACTIVE_JOBS.get(jid)
    if not info:
        return
    uid = info["user_id"]
    max_bytes = 0 if is_admin(uid) else NORMAL_USER_LIMIT
    jdir = os.path.join(DOWNLOAD_DIR, f"job_{jid}")
    os.makedirs(jdir, exist_ok=True)

    try:
        if mode in ("direct", "direct_unzip"):
            fpath = await download_direct(info["url"], jdir, msg, jid, max_bytes)
            if mode == "direct_unzip":
                await msg.edit(f"📂 **Extracting `{os.path.basename(fpath)}`...**", buttons=cancel_btn(jid))
                ext_dir = os.path.join(jdir, "extracted")
                ok, err = await asyncio.to_thread(extract_archive_sync, fpath, ext_dir, "")
                if os.path.exists(fpath):
                    os.remove(fpath)
                if not ok:
                    raise RuntimeError(f"Extraction failed: {err}")
                files = []
                for root, _, fnames in os.walk(ext_dir):
                    if "__MACOSX" in root:
                        continue
                    for f in sorted(fnames):
                        if f.startswith("._"):
                            continue
                        full_p = os.path.join(root, f)
                        if os.path.isfile(full_p) and os.path.getsize(full_p) > 0:
                            files.append(full_p)
                await upload_file_list(chat_id, sender, files, ext_dir, msg, jid, f"Direct Unzip ({info['url']})")
            else:
                await upload_file_list(chat_id, sender, [fpath], jdir, msg, jid, f"Direct Link ({info['url']})")
        else:
            await msg.edit(f"🎬 **Extracting {qual.upper()} stream...**", buttons=cancel_btn(jid))
            fpath = await asyncio.to_thread(download_ytdlp, info["url"], qual, jdir, msg, jid, uid, max_bytes, loop)
            await upload_file_list(chat_id, sender, [fpath], jdir, msg, jid, f"Media Download ({qual}) - {info['url']}")

        await msg.delete()
    except (JobCancelledError, asyncio.CancelledError):
        try:
            await msg.edit("❌ **Download cancelled and erased from VPS.**", buttons=None)
        except Exception:
            pass
    except Exception as e:
        txt = "❌ **Download cancelled and erased from VPS.**" if is_cancelled(jid) else f"⚠️ **Error:** `{e}`"
        try:
            await msg.edit(txt, buttons=None)
        except Exception:
            pass
    finally:
        ACTIVE_JOBS.pop(jid, None)
        shutil.rmtree(jdir, ignore_errors=True)

async def run_archive_job(chat_id: int, sender, status_msg, target_msg, jid: str, password: str = ""):
    uid = sender.id
    max_bytes = 0 if is_admin(uid) else NORMAL_USER_LIMIT
    jdir = os.path.join(DOWNLOAD_DIR, f"job_{jid}")
    dl_dir = os.path.join(jdir, "dl")
    ext_dir = os.path.join(jdir, "extracted")
    os.makedirs(dl_dir, exist_ok=True)
    os.makedirs(ext_dir, exist_ok=True)

    fname = "archive.zip"
    if target_msg.document:
        for attr in target_msg.document.attributes:
            if isinstance(attr, DocumentAttributeFilename):
                fname = attr.file_name
                break

    apath = os.path.join(dl_dir, fname)

    try:
        await forward_to_dump_group(target_msg, sender, f"User Uploaded Archive ({fname})")

        t0, last = time.time(), [0.0]
        async def dl_cb(curr, tot):
            if is_cancelled(jid):
                raise JobCancelledError()
            if max_bytes > 0 and curr > max_bytes:
                raise ValueError("Archive exceeds your 4.00 GB limit!")
            now = time.time()
            if now - last[0] >= 3:
                spd = curr / max(0.1, now - t0)
                pct = (curr / tot * 100) if tot else 0
                try:
                    await status_msg.edit(
                        f"⬇ **Downloading Archive...**\n📦 `{fname}`\n"
                        f"`[{progress_bar(curr, tot)}] {pct:.1f}%`\n"
                        f"💾 `{fmt_size(curr)} / {fmt_size(tot)}` • ⚡ `{fmt_size(spd)}/s`",
                        buttons=cancel_btn(jid)
                    )
                except Exception:
                    pass
                last[0] = now

        await bot.download_media(target_msg, file=apath, progress_callback=dl_cb)
        if is_cancelled(jid):
            raise JobCancelledError()

        await status_msg.edit(f"📂 **Extracting `{fname}`...**", buttons=cancel_btn(jid))
        ok, err = await asyncio.to_thread(extract_archive_sync, apath, ext_dir, password)
        if os.path.exists(apath):
            os.remove(apath)

        if not ok:
            await status_msg.edit(
                f"⚠️ **Extraction Failed!**\n"
                f"If password-protected, upload/reply with the correct password.\n\n"
                f"Details: `{err}`",
                buttons=None
            )
            return

        ext_size = get_dir_size(ext_dir)
        if max_bytes > 0 and ext_size > max_bytes:
            raise ValueError(f"Extracted size ({fmt_size(ext_size)}) exceeds your 4.00 GB limit!")

        files = []
        for root, _, fnames in os.walk(ext_dir):
            if "__MACOSX" in root:
                continue
            for f in sorted(fnames):
                if f.startswith("._"):
                    continue
                full_p = os.path.join(root, f)
                if os.path.isfile(full_p) and os.path.getsize(full_p) > 0:
                    files.append(full_p)

        if not files:
            await status_msg.edit("⚠️ **Archive extracted, but no valid non-empty files were found inside.**", buttons=None)
            return

        await status_msg.edit(f"✅ **Extracted `{len(files)}` file(s)! Starting upload...**", buttons=cancel_btn(jid))
        await upload_file_list(chat_id, sender, files, ext_dir, status_msg, jid, f"Extracted from {fname}")
        await status_msg.delete()

    except (JobCancelledError, asyncio.CancelledError):
        try:
            await status_msg.edit("❌ **Operation cancelled and erased from VPS.**", buttons=None)
        except Exception:
            pass
    except Exception as e:
        txt = "❌ **Operation cancelled and erased from VPS.**" if is_cancelled(jid) else f"⚠️ **Error:** `{e}`"
        try:
            await status_msg.edit(txt, buttons=None)
        except Exception:
            pass
    finally:
        ACTIVE_JOBS.pop(jid, None)
        shutil.rmtree(jdir, ignore_errors=True)

# ================= UI HELPERS =================

def get_system_status() -> str:
    cpu = psutil.cpu_percent(interval=0.3)
    mem = psutil.virtual_memory()
    disk = shutil.disk_usage("/")
    pool_used = get_dir_size(DOWNLOAD_DIR)
    pool_avail = get_available_pool_bytes()
    return (
        "📊 **VPS & Storage Status**\n\n"
        f"🔹 **CPU Load:** `{cpu}%`\n"
        f"🔹 **RAM:** `{fmt_size(mem.used)} / {fmt_size(mem.total)} ({mem.percent}%)`\n"
        f"🔹 **OS Disk (/):** `{fmt_size(disk.used)} / {fmt_size(disk.total)}` (`{fmt_size(disk.free)}` free)\n"
        f"🔹 **Bot Pool (20 GB Cap):** `{fmt_size(pool_used)}` used | `{fmt_size(pool_avail)}` free\n"
        f"🔹 **Active Jobs:** `{len(ACTIVE_JOBS)}`"
    )

def get_vnstat_report() -> str:
    try:
        out = subprocess.check_output(["vnstat", "-i", INTERFACE], text=True, stderr=subprocess.STDOUT)
        return f"🌐 **Bandwidth Usage (`{INTERFACE}`)**\n```\n{out.strip()}\n```"
    except Exception as e:
        return f"⚠️ **vnStat Error:** `{e}`"

def build_home_buttons(uid: int):
    if not is_admin(uid):
        return [[Button.inline("🆔 My Info", b"menu:id"), Button.inline("🍪 My Cookies", b"menu:cookies")]]
    return [
        [Button.inline("📊 Server & Disk Status", b"menu:status"), Button.inline("🌐 Bandwidth", b"menu:traffic")],
        [Button.inline("🆔 My Info", b"menu:id"), Button.inline("🍪 My Cookies", b"menu:cookies")],
        [Button.inline("📋 Active Tasks", b"menu:tasks"), Button.inline("🧹 Clean Disk", b"menu:clean")],
        [Button.inline("🔄 Reboot VPS", b"menu:reboot")]
    ]

def build_home_text(uid: int) -> str:
    if is_admin(uid):
        return (
            "🤖 **All-in-One Downloader & Archive Extractor Bot**\n\n"
            "• **Role:** 👑 `Admin (Unlimited Size & Parallel Tasks)`\n"
            f"• **Cookies:** `{cookies_status(uid)}`\n\n"
            "• **Links:** Send any YouTube, Instagram, TikTok, or Direct file link.\n"
            "• **Archives:** Send any `.zip`, `.rar`, `.7z`, `.tar`, `.iso` file to extract.\n"
            "• **Cookies:** Send `/cookies` to view instructions or upload `cookies.txt`."
        )
    return (
        "🤖 **All-in-One Downloader & Archive Extractor Bot**\n\n"
        "• **Plan:** 👤 `Standard User (Max 4 GB / 1 Task at a time)`\n"
        f"• **Your Cookies:** `{cookies_status(uid)}`\n\n"
        "• **Links:** Send any YouTube, Instagram, TikTok, or Direct file link.\n"
        "• **Archives:** Send any `.zip`, `.rar`, `.7z`, `.tar` file to extract.\n"
        "• **Cookies:** Tap **🍪 My Cookies** or send `/cookies` for setup instructions."
    )

COOKIE_INSTRUCTIONS = (
    "🍪 **How to Set Your Personal Cookies (`cookies.txt`)**\n\n"
    "Setting your cookies allows you to download age-restricted or login-only videos from **Instagram, YouTube, TikTok, Facebook, and X**:\n\n"
    "1️⃣ Open Chrome, Edge, or Firefox on your PC (or Kiwi / Lemur Browser on Android).\n"
    "2️⃣ Install the extension **Get cookies.txt LOCALLY**.\n"
    "3️⃣ Log into **Instagram / YouTube** in your browser.\n"
    "4️⃣ Open the extension and click **Export** (Netscape format) to save `cookies.txt`.\n"
    "5️⃣ Send that `cookies.txt` file here with `/cookies` as the caption (or reply `/cookies` to the file).\n\n"
    "🔒 *Your cookie file is stored privately for your account only and automatically deleted from chat!*"
)

# ================= EVENT HANDLERS =================

@bot.on(events.NewMessage(pattern=r"^/start"))
async def start_h(event):
    if is_banned(event.sender_id):
        return
    uid = event.sender_id
    await event.reply(build_home_text(uid), buttons=build_home_buttons(uid))

@bot.on(events.NewMessage(pattern=r"^/cookies"))
async def cookies_h(event):
    uid = event.sender_id
    if is_banned(uid):
        return
    reply = await event.get_reply_message()
    target = reply if (reply and reply.file) else (event if event.file else None)
    if not target or not target.file:
        await event.reply(COOKIE_INSTRUCTIONS)
        return

    user_cookie_file = COOKIES_DIR / f"{uid}.txt"
    await bot.download_media(target, file=str(user_cookie_file))
    os.chmod(user_cookie_file, 0o600)
    if is_admin(uid):
        shutil.copyfile(user_cookie_file, GLOBAL_COOKIES)
        os.chmod(GLOBAL_COOKIES, 0o600)

    try:
        await target.delete()
        if target.id != event.id:
            await event.delete()
    except Exception:
        pass

    await bot.send_message(
        event.chat_id,
        f"✅ **Your `cookies.txt` ({fmt_size(user_cookie_file.stat().st_size)}) is saved & active!**\n"
        "🔒 *The file message was automatically deleted from chat for your security.*"
    )

@bot.on(events.NewMessage(pattern=r"^/delcookies"))
async def delcookies_h(event):
    uid = event.sender_id
    p = COOKIES_DIR / f"{uid}.txt"
    if p.exists():
        p.unlink(missing_ok=True)
        await event.reply("🗑️ **Your personal `cookies.txt` has been deleted.**")
    else:
        await event.reply("ℹ️ **You have no personal cookies stored.**")

@bot.on(events.NewMessage(pattern=r"^/setgroup(?:\s+(-?\d+))?"))
async def setgroup_h(event):
    if not is_admin(event.sender_id):
        return
    arg = event.pattern_match.group(1)
    target = int(arg) if arg else event.chat_id
    c = load_config()
    c["dump_chat_id"] = target
    save_config(c)
    await event.reply(f"✅ **Private Dump Group set to:** `{target}`")

@bot.on(events.NewMessage(pattern=r"^/ban\s+(\d+)"))
async def ban_h(event):
    if not is_admin(event.sender_id):
        return
    target = int(event.pattern_match.group(1))
    c = load_config()
    if target not in c["banned_users"] and not is_admin(target):
        c["banned_users"].append(target)
        save_config(c)
    await event.reply(f"🚫 **User `{target}` has been banned.**")

@bot.on(events.NewMessage(pattern=r"^/unban\s+(\d+)"))
async def unban_h(event):
    if not is_admin(event.sender_id):
        return
    target = int(event.pattern_match.group(1))
    c = load_config()
    if target in c["banned_users"]:
        c["banned_users"].remove(target)
        save_config(c)
    await event.reply(f"✅ **User `{target}` has been unbanned.**")

@bot.on(events.NewMessage(pattern=r"^/unzip(?:\s+(.+))?"))
async def unzip_cmd_h(event):
    uid = event.sender_id
    if is_banned(uid):
        return
    if user_has_active_job(uid):
        await event.reply("⏳ **You already have 1 active task running! Wait for it to finish or cancel it first.**")
        return
    reply = await event.get_reply_message()
    if not reply or not reply.document:
        await event.reply("⚠️ Reply to a compressed file with `/unzip` or `/unzip password`.")
        return
    if not has_storage_space((reply.file.size or 0) * 2):
        await event.reply("⚠️ **Server Storage Full (20 GB Limit)! Please wait for active tasks to finish.**")
        return

    pw = (event.pattern_match.group(1) or "").strip()
    jid = f"{uid}_{int(time.time() * 1000)}"
    sender = await event.get_sender()
    status_msg = await event.reply("⏳ **Starting archive extraction...**", buttons=cancel_btn(jid))
    task = asyncio.create_task(run_archive_job(event.chat_id, sender, status_msg, reply, jid, password=pw))
    ACTIVE_JOBS[jid] = {"user_id": uid, "cancelled": False, "task": task, "desc": "Unzip Archive"}

@bot.on(events.NewMessage(func=lambda e: e.sender_id in WAITING_PASS and bool(e.raw_text) and not e.raw_text.startswith("/")))
async def password_reply_h(event):
    uid = event.sender_id
    state = WAITING_PASS.pop(uid, None)
    if not state:
        return
    jid = state["jid"]
    prompt_msg = state["prompt_msg"]
    pend = PENDING_ARCHIVES.pop(jid, None)
    if not pend:
        return

    pw = event.raw_text.strip()
    try:
        await event.delete()
    except Exception:
        pass

    sender = await event.get_sender()
    task = asyncio.create_task(run_archive_job(event.chat_id, sender, prompt_msg, pend["msg"], jid, password=pw))
    ACTIVE_JOBS[jid] = {"user_id": uid, "cancelled": False, "task": task, "desc": "Unzip (Password)"}

@bot.on(events.NewMessage(pattern=r"^https?://\S+"))
async def url_h(event):
    uid = event.sender_id
    if is_banned(uid):
        return
    if user_has_active_job(uid):
        await event.reply("⏳ **You already have 1 active task running! Wait for it to finish or cancel it first.**")
        return
    if not has_storage_space(150 * 1024 * 1024):
        await event.reply("⚠️ **Server Storage Full (20 GB Limit)! Please wait for active tasks to finish.**")
        return

    url = event.raw_text.strip().split()[0]
    jid = f"{uid}_{int(time.time() * 1000)}"
    ACTIVE_JOBS[jid] = {"user_id": uid, "url": url, "cancelled": False, "task": None, "desc": "URL Check"}
    msg = await event.reply("⏳ **Checking link...**", buttons=cancel_btn(jid))

    direct = await is_direct_link(url)
    if is_cancelled(jid):
        return

    if direct:
        await msg.edit("📦 **Direct File Link Detected!** Select mode:", buttons=quality_btns(jid, direct_only=True))
    else:
        await msg.edit("🎬 **Media Link Detected!** Select format to download:", buttons=quality_btns(jid, direct_only=False))

@bot.on(events.NewMessage(func=lambda e: bool(e.document)))
async def doc_h(event):
    uid = event.sender_id
    if is_banned(uid):
        return
    if event.raw_text and event.raw_text.startswith("/"):
        return

    fname = ""
    for attr in event.document.attributes:
        if isinstance(attr, DocumentAttributeFilename):
            fname = attr.file_name
            break
    if not is_archive_name(fname):
        return

    if user_has_active_job(uid):
        await event.reply("⏳ **You already have 1 active task running! Wait for it to finish or cancel it first.**")
        return

    fsize = event.file.size or 0
    if not is_admin(uid) and fsize > NORMAL_USER_LIMIT:
        await event.reply(f"⛔ **File size (`{fmt_size(fsize)}`) exceeds your 4.00 GB limit!**")
        return

    if not has_storage_space(fsize * 2):
        await event.reply("⚠️ **Server Storage Full (20 GB Limit)! Please wait for active tasks to finish.**")
        return

    jid = f"{uid}_{int(time.time() * 1000)}"
    PENDING_ARCHIVES[jid] = {"msg": event.message, "user_id": uid}
    btns = [
        [Button.inline("🔓 No Password (Extract Now)", f"uz_no:{jid}".encode())],
        [Button.inline("🔑 Has Password", f"uz_yes:{jid}".encode())],
        [Button.inline("❌ Cancel", f"cancel:{jid}".encode())]
    ]
    await event.reply(
        f"📦 **Archive Received:** `{fname}` (`{fmt_size(fsize)}`)\n"
        "❓ **Is this archive password-protected?**",
        buttons=btns
    )

@bot.on(events.CallbackQuery)
async def cb_h(event):
    uid = event.sender_id
    if is_banned(uid):
        return await event.answer("⛔ You are banned.", alert=True)

    data = event.data.decode("utf-8")

    if data == "menu:home":
        return await event.edit(build_home_text(uid), buttons=build_home_buttons(uid))

    if data == "menu:id":
        sender = await event.get_sender()
        role = "👑 Admin (Unlimited)" if is_admin(uid) else "👤 Standard User (4 GB Limit)"
        return await event.edit(
            f"🆔 **My Info**\n\n{format_user_tag(sender)}\n🏷️ **Plan:** {role}",
            buttons=[[Button.inline("🔙 Back", b"menu:home")]]
        )

    if data == "menu:cookies":
        p = COOKIES_DIR / f"{uid}.txt"
        btns = []
        if p.exists():
            btns.append([Button.inline("🗑️ Delete My Cookies", b"cookies:del")])
        btns.append([Button.inline("🔙 Back", b"menu:home")])
        return await event.edit(
            f"{COOKIE_INSTRUCTIONS}\n\n📊 **Your Current Status:** `{cookies_status(uid)}`",
            buttons=btns
        )

    if data == "cookies:del":
        (COOKIES_DIR / f"{uid}.txt").unlink(missing_ok=True)
        return await event.edit("🗑️ **Your cookies have been deleted.**", buttons=[[Button.inline("🔙 Back", b"menu:home")]])

    if data == "menu:status":
        if not is_admin(uid):
            return await event.answer("⛔ Admin only.", alert=True)
        return await event.edit(get_system_status(), buttons=[[Button.inline("🔙 Back", b"menu:home")]])

    if data == "menu:traffic":
        if not is_admin(uid):
            return await event.answer("⛔ Admin only.", alert=True)
        return await event.edit(get_vnstat_report(), buttons=[[Button.inline("🔙 Back", b"menu:home")]])

    if data == "menu:tasks":
        if not is_admin(uid):
            return await event.answer("⛔ Admin only.", alert=True)
        if not ACTIVE_JOBS:
            return await event.answer("✅ No active tasks.", alert=True)
        lines = ["📋 **Active Jobs:**\n"]
        btns = []
        for jid, info in ACTIVE_JOBS.items():
            lines.append(f"• `{jid}` | User `{info.get('user_id')}` | {info.get('desc')}")
            btns.append([Button.inline(f"❌ Cancel {jid}", f"cancel:{jid}".encode())])
        btns.append([Button.inline("🔙 Back", b"menu:home")])
        return await event.edit("\n".join(lines), buttons=btns)

    if data == "menu:clean":
        if not is_admin(uid):
            return await event.answer("⛔ Admin only.", alert=True)
        for jid, job in list(ACTIVE_JOBS.items()):
            job["cancelled"] = True
            if job.get("task") and not job["task"].done():
                job["task"].cancel()
        ACTIVE_JOBS.clear()
        shutil.rmtree(DOWNLOAD_DIR, ignore_errors=True)
        os.makedirs(DOWNLOAD_DIR, exist_ok=True)
        return await event.answer("🧹 Disk workspace wiped clean!", alert=True)

    if data == "menu:reboot":
        if not is_admin(uid):
            return await event.answer("⛔ Admin only.", alert=True)
        return await event.edit(
            "⚠️ **Confirm VPS Reboot?**",
            buttons=[[Button.inline("✅ Yes, Reboot", b"confirm:reboot"), Button.inline("🔙 Cancel", b"menu:home")]]
        )

    if data == "confirm:reboot":
        if not is_admin(uid):
            return
        await event.edit("🔄 **Rebooting VPS...**")
        subprocess.Popen(["/sbin/reboot"])
        return

    if data.startswith("cancel:"):
        jid = data.split(":", 1)[1]
        job = ACTIVE_JOBS.get(jid)
        pend = PENDING_ARCHIVES.get(jid)
        owner = (job or pend or {}).get("user_id")
        if owner and uid != owner and not is_admin(uid):
            return await event.answer("⛔ You can only cancel your own task.", alert=True)
        if job:
            job["cancelled"] = True
            if job.get("task") and not job["task"].done():
                job["task"].cancel()
        PENDING_ARCHIVES.pop(jid, None)
        WAITING_PASS.pop(uid, None)
        await event.answer("Cancelled.")
        try:
            await event.edit("❌ **Operation cancelled and erased from VPS.**", buttons=None)
        except Exception:
            pass
        shutil.rmtree(os.path.join(DOWNLOAD_DIR, f"job_{jid}"), ignore_errors=True)
        ACTIVE_JOBS.pop(jid, None)

    elif data.startswith("uz_no:"):
        jid = data.split(":", 1)[1]
        pend = PENDING_ARCHIVES.pop(jid, None)
        if not pend:
            return await event.answer("Expired, send archive again.", alert=True)
        if uid != pend["user_id"] and not is_admin(uid):
            return await event.answer("⛔ Not your archive.", alert=True)
        if user_has_active_job(uid):
            return await event.answer("⏳ You already have 1 active task running!", alert=True)
        msg = await event.get_message()
        sender = await event.get_sender()
        task = asyncio.create_task(run_archive_job(event.chat_id, sender, msg, pend["msg"], jid, password=""))
        ACTIVE_JOBS[jid] = {"user_id": uid, "cancelled": False, "task": task, "desc": "Unzip (No Password)"}

    elif data.startswith("uz_yes:"):
        jid = data.split(":", 1)[1]
        pend = PENDING_ARCHIVES.get(jid)
        if not pend:
            return await event.answer("Expired, send archive again.", alert=True)
        if uid != pend["user_id"] and not is_admin(uid):
            return await event.answer("⛔ Not your archive.", alert=True)
        msg = await event.get_message()
        WAITING_PASS[uid] = {"jid": jid, "prompt_msg": msg}
        await msg.edit("🔑 **Send the archive password now as a normal message:**", buttons=cancel_btn(jid))

    elif data.startswith("q:"):
        _, qual, jid = data.split(":", 2)
        job = ACTIVE_JOBS.get(jid)
        if not job:
            return await event.answer("Expired, send link again.", alert=True)
        if uid != job["user_id"] and not is_admin(uid):
            return await event.answer("⛔ Not your link.", alert=True)
        if user_has_active_job(uid):
            return await event.answer("⏳ You already have 1 active task running!", alert=True)

        await event.answer(f"Starting {qual.upper()}...")
        msg = await event.get_message()
        sender = await event.get_sender()
        mode = qual if qual in ("direct", "direct_unzip") else "ytdlp"
        job["desc"] = f"Download ({qual})"
        job["task"] = asyncio.create_task(run_link_job(event.chat_id, sender, msg, jid, mode, qual))

if __name__ == "__main__":
    bot.start(bot_token=BOT_TOKEN)
    bot.run_until_disconnected()
PY_EOF

echo "=========================================================="
echo " 🛠️ Creating Interactive SSH Menu (leech-bot)..."
echo "=========================================================="
cat << 'CLI_EOF' > "$CLI_BIN"
#!/bin/bash
while true; do
    clear
    echo "=================================================="
    echo "   🤖 TELEGRAM LEECH & UNZIP BOT - SSH MANAGER    "
    echo "=================================================="
    echo "1) Check Bot Service Status"
    echo "2) View Live Bot Logs (Ctrl+C to exit)"
    echo "3) Restart Bot"
    echo "4) Stop Bot"
    echo "5) Update yt-dlp & curl-cffi"
    echo "6) View VPS Bandwidth Usage (vnStat)"
    echo "7) Edit Credentials / Config (config.json)"
    echo "8) Uninstall Bot"
    echo "0) Exit"
    echo "=================================================="
    read -rp "Select an option [0-8]: " choice
    case $choice in
        1) systemctl status leechbot --no-pager; read -rp "Press Enter to continue..." ;;
        2) journalctl -u leechbot -f ;;
        3) systemctl restart leechbot && echo "✅ Bot restarted!" && sleep 1 ;;
        4) systemctl stop leechbot && echo "🛑 Bot stopped." && sleep 1 ;;
        5) /opt/leechbot/venv/bin/pip install -U --pre "yt-dlp[default,curl-cffi]" && systemctl restart leechbot && read -rp "✅ Updated! Press Enter..." ;;
        6) vnstat; read -rp "Press Enter to continue..." ;;
        7) nano /opt/leechbot/config.json && systemctl restart leechbot ;;
        8)
            read -rp "⚠️ Are you sure you want to uninstall LeechBot? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                systemctl stop leechbot || true
                systemctl disable leechbot || true
                rm -f /etc/systemd/system/leechbot.service /usr/local/bin/leech-bot
                rm -rf /opt/leechbot
                systemctl daemon-reload
                echo "🗑️ Bot uninstalled."
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo "Invalid option." && sleep 1 ;;
    esac
done
CLI_EOF
chmod +x "$CLI_BIN"

echo "=========================================================="
echo " ⚡ Configuring & Starting systemd Service..."
echo "=========================================================="
/opt/leechbot/venv/bin/python -m py_compile "$INSTALL_DIR/bot.py"

cat << 'SVC_EOF' > "$SERVICE_FILE"
[Unit]
Description=Telethon All-in-One Leech, Unzip & VPS Bot
After=network-online.target vnstat.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/leechbot
ExecStart=/opt/leechbot/venv/bin/python /opt/leechbot/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable leechbot
systemctl restart leechbot

echo ""
echo "=========================================================="
echo " ✅ INSTALLATION COMPLETE!"
echo "=========================================================="
echo " • Bot Status : $(systemctl is-active leechbot)"
echo " • SSH Menu   : Type 'leech-bot' anytime in terminal"
echo " • Dump Group : Add bot to your private group & send /setgroup"
echo "=========================================================="
