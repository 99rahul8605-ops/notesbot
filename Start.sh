#!/usr/bin/env bash
# Notes Search Bot — startup script
# Usage: ./start.sh
#
# Bot ek detached `screen` session me chalta hai (agar screen installed hai)
# — isse SSH/terminal band karne par bhi bot chalta rehta hai.
set -euo pipefail

# Script ka absolute path nikal lo (screen session ke andar se bhi sahi
# directory me chal sake, chahe kahin se bhi ./start.sh chalao)
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SCRIPT_PATH")"

SESSION_NAME="notesbot"

# ---------- 0) Background me (screen session) relaunch karo ----------
# NOTESBOT_FOREGROUND already set matlab hum khud screen session ke andar
# hain — ab seedha aage badho (setup + run loop).
if [ -z "${NOTESBOT_FOREGROUND:-}" ]; then
    if command -v screen >/dev/null 2>&1; then
        if screen -list 2>/dev/null | grep -q "\.${SESSION_NAME}[[:space:]]"; then
            echo "✅ Bot pehle se '$SESSION_NAME' screen session me chal raha hai."
            echo "   Dekhne ke liye:  screen -r $SESSION_NAME"
            exit 0
        fi
        echo "🖥️  '$SESSION_NAME' screen session me bot background me start kar raha hoon..."
        NOTESBOT_FOREGROUND=1 screen -dmS "$SESSION_NAME" bash "$SCRIPT_PATH"
        sleep 1
        echo "✅ Bot background me chal raha hai — SSH/terminal band karo to bhi chalta rahega."
        echo ""
        echo "   Live logs dekhne ke liye:        screen -r $SESSION_NAME"
        echo "   (screen ke andar se bahar aane ke liye, bot rukega NAHI: Ctrl+A phir D)"
        echo "   Bot poori tarah rokne ke liye:   screen -S $SESSION_NAME -X quit"
        exit 0
    else
        echo "ℹ️  'screen' installed nahi hai — bot is terminal me foreground me chalega"
        echo "    (terminal/SSH band karne par bot bhi ruk jayega)."
        echo "    Background me chalane ke liye:  sudo apt install screen   # (ya) yum install screen"
        echo ""
    fi
fi

# ---------- 0.5) Git pull (agar ye ek git repo hai) ----------
if [ -d ".git" ]; then
    if command -v git >/dev/null 2>&1; then
        echo "🔄 Git repo mila -- latest code update kar raha hoon..."
        if git pull --ff-only 2>/tmp/git_err.log; then
            cat /tmp/git_err.log
        else
            echo "⚠️ git pull fail hua (local changes / conflict / network issue ho sakta hai)."
            echo "   Purana code se hi aage badh raha hoon. Manually check karo:"
            cat /tmp/git_err.log
        fi
        rm -f /tmp/git_err.log
    fi
fi

# ---------- 1) .env check ----------
if [ ! -f ".env" ]; then
    echo "❌ .env file nahi mili."
    if [ -f ".env.example" ]; then
        echo "   .env.example ko copy karke .env banao aur values fill karo:"
        echo "   cp .env.example .env"
    else
        echo "   .env banao jisme ye zaroori variables ho:"
        echo "   API_ID=..., API_HASH=..., BOT_TOKEN=..., CHANNEL=..."
    fi
    exit 1
fi

# ---------- 2) Python virtual environment ----------
if [ ! -d "venv" ]; then
    echo "📦 Pehli baar chal raha hai — virtual environment bana raha hoon..."
    python3 -m venv venv
fi
# shellcheck disable=SC1091
source venv/bin/activate

# ---------- 3) Dependencies install/update ----------
_pip_install() {
    # Pehle normal install try karo. Kuch systems (newer Debian/Ubuntu,
    # PEP 668 "externally-managed-environment") isse block kar dete hain —
    # tab --break-system-packages ke saath retry karo. venv ke andar ye
    # generally safe hai (system Python ko touch nahi karta).
    if ! pip install --quiet "$@" 2>/tmp/pip_err.log; then
        if grep -qi "externally-managed-environment" /tmp/pip_err.log; then
            echo "ℹ️ System pip ne block kiya (externally-managed-environment) — "
            echo "   --break-system-packages ke saath retry kar raha hoon..."
            pip install --quiet --break-system-packages "$@"
        else
            cat /tmp/pip_err.log
            return 1
        fi
    fi
    rm -f /tmp/pip_err.log
}

if [ -f "requirements.txt" ]; then
    echo "📦 Dependencies check kar raha hoon..."
    _pip_install --upgrade pip
    _pip_install -r requirements.txt
else
    echo "⚠️ requirements.txt nahi mili, seedha telethon/python-dotenv install kar raha hoon."
    _pip_install telethon python-dotenv
fi

# ---------- 4) Single-instance lock ----------
LOCK_FILE="notes_bot.lock"
if [ -f "$LOCK_FILE" ]; then
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "❌ Bot pehle se chal raha hai (PID $OLD_PID). Pehle usko band karo:"
        echo "   kill $OLD_PID"
        exit 1
    fi
    echo "🧹 Purani stale lock file mili (process $OLD_PID zinda nahi), saaf kar raha hoon."
    rm -f "$LOCK_FILE"
fi

# ---------- 5) Run with auto-restart on crash ----------
echo "🚀 Bot start ho raha hai... (Ctrl+C se rokne ke liye)"
trap 'echo "🛑 Bot band ho raha hai..."; rm -f "$LOCK_FILE"; exit 0' INT TERM

while true; do
    python3 bot.py
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Bot normally band hua."
        break
    fi
    echo "⚠️ Bot crash hua (exit code $EXIT_CODE). 5 second me restart..."
    sleep 5
done
