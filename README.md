# 🚀 All-in-One Telegram Leech, Unzip & Media Downloader Bot

A powerful, secure, and lightweight Telegram bot designed for high-speed file leeching, media downloading, and archive extraction on an Ubuntu VPS. This script installs a persistent `systemd` background service powered by MTProto (`Telethon`), allowing you and your users to download videos from 1,500+ platforms, leech direct links, extract password-protected archives, and monitor server health—all from an interactive Telegram dashboard or a built-in SSH menu.

## ✨ Features

* 🎬 **Universal Media Downloader (`yt-dlp` + `curl-cffi`):** Download videos from YouTube, Instagram, TikTok, Facebook, X, and 1,500+ sites with built-in TLS browser impersonation. Choose between `1080p`, `720p`, `480p`, `360p`, or `MP3` audio.
* 📦 **Smart Direct Link Leeching:** Automatically detects direct download links and offers instant **Direct File Download** or **Direct Download + Auto-Unzip** with live progress bars, transfer speed, and ETA.
* 📂 **Instant Archive Extractor:** Upload or forward any `.zip`, `.rar` (including RAR5), `.7z`, `.tar`, `.tar.gz`, `.xz`, or `.iso` file. The bot automatically prompts for **No Password** or **Has Password** and uploads all extracted files.
* ✂️ **1.9 GB Smart File Splitting:** Bypasses the standard 50 MB Bot API limit using MTProto to upload files up to 2 GB per part, automatically splitting larger videos losslessly via `ffmpeg` or `split`.
* 🍪 **Per-User `cookies.txt` Support:** Users and admins can upload their own Netscape `cookies.txt` file via `/cookies` to bypass login walls and age restrictions. The bot secures the file (`chmod 600`) and immediately deletes the message from chat history.
* 🛡️ **Role-Based Limits & 20 GB Disk Guard:** Standard users are capped at **4 GB per task** and **1 parallel task** (with a simplified `🆔 My Info` & `🍪 My Cookies` menu), while Admins enjoy **unlimited file sizes**, **unlimited parallel tasks**, and full server controls. All temporary files are automatically wiped after upload to protect the 20 GB workspace pool.
* 📥 **Private Group Logging & User Tagging:** Bind a private group with `/setgroup` to automatically forward every user-uploaded archive and bot-downloaded file with the user's clickable **Name**, **@Username**, and **Telegram ID**.
* 📊 **Live VPS Monitoring & Persistent Bandwidth:** Admins can check real-time CPU, RAM, OS Disk, and Bot Pool usage, track persistent network traffic across reboots via `vnStat`, wipe the download cache, or safely reboot the VPS from Telegram.
* 💻 **Interactive SSH Menu:** Type `leech-bot` in your terminal anytime to check service status, view live logs, update `yt-dlp`, edit `config.json`, or uninstall the bot.

## 📋 Prerequisites

* An **Ubuntu VPS** (20.04, 22.04, or 24.04 recommended) with `root` access.
* A **Telegram App `API_ID` & `API_HASH`** (Get these from [my.telegram.org](https://my.telegram.org)).
* A **Telegram Bot Token** (Create one by messaging [@BotFather](https://t.me/BotFather) on Telegram).
* Your **Numeric Telegram User ID** (Get this by messaging [@userinfobot](https://t.me/userinfobot)).

## ⚙️ One-Line Installation

Log into your VPS via SSH as the `root` user and paste the following command:

```bash
bash <(curl -Ls [https://raw.githubusercontent.com/SPW-SL/Telegram_Leech_Unzip_BOT/main/install.sh](https://raw.githubusercontent.com/SPW-SL/Telegram_Leech_Unzip_BOT/main/install.sh))
```

## 🤖 Telegram Commands

| Command | Access | Description |
| :--- | :--- | :--- |
| `/start` | Everyone | Opens the interactive bot dashboard (`My Info` & `My Cookies` for users; full VPS & task controls for Admins). |
| `/cookies` | Everyone | Displays cookie setup instructions, or saves your attached `cookies.txt` file and deletes it from chat. |
| `/delcookies` | Everyone | Deletes your personal `cookies.txt` file from the server. |
| `/unzip [pass]` | Everyone | Reply to any compressed archive to extract it (or simply send the archive directly for interactive buttons). |
| `/setgroup` | Admin Only | Run inside your private Telegram group (or pass `/setgroup -100...`) to enable automatic file forwarding and user tagging. |
| `/ban <id>` | Admin Only | Bans a Telegram User ID from using the bot. |
| `/unban <id>` | Admin Only | Unbans a Telegram User ID. |

## 🖥️ SSH Management Menu

Once installed, manage your bot anytime from your VPS terminal by running:

```bash
leech-bot
```
