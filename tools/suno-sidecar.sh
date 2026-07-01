#!/usr/bin/env bash
# One command to run a local Suno sidecar so Gosan can generate with one click.
# Prompts for your Suno cookie SECURELY (hidden input — never echoed, never in shell
# history, never pasted into chat).
#
#   tools/suno-sidecar.sh
#
# Your Suno cookie: log in at suno.com → DevTools (⌥⌘I) → Network → filter "clerk" →
# reload → click a request to clerk.suno.com → Request Headers → copy the full "cookie"
# value (must include __client=…). Paste it at the prompt.
#
# Leave it running. In Gosan → Generate, the dot turns green when the cookie is valid.
set -euo pipefail

DIR="${SUNO_SIDECAR_DIR:-$HOME/.gosan/suno-api}"
command -v git >/dev/null  || { echo "git is required."; exit 1; }
command -v node >/dev/null || { echo "Node.js is required (brew install node)."; exit 1; }

# --- Cookie (hidden prompt unless already in the environment) ---
if [ -z "${SUNO_COOKIE:-}" ]; then
  echo "Paste your Suno cookie (from clerk.suno.com → Request Headers → cookie), then Enter."
  echo "It will NOT be shown as you paste."
  read -rs SUNO_COOKIE
  echo
fi
[ -n "${SUNO_COOKIE:-}" ] || { echo "No cookie entered — aborting."; exit 1; }

# --- Optional 2captcha key (only needed if Suno throws a captcha) ---
if [ -z "${TWOCAPTCHA_KEY:-}" ]; then
  read -rp "2captcha API key (optional — press Enter to skip): " TWOCAPTCHA_KEY || true
fi

if [ ! -d "$DIR/.git" ]; then
  echo "→ Cloning gcui-art/suno-api into $DIR"
  git clone --depth 1 https://github.com/gcui-art/suno-api "$DIR"
fi
cd "$DIR"

# Next.js reads .env.local; written fresh each run, never committed.
{
  printf 'SUNO_COOKIE=%s\n' "$SUNO_COOKIE"
  printf 'BROWSER=chromium\nBROWSER_GHOST_CURSOR=false\nBROWSER_HEADLESS=true\n'
  [ -n "${TWOCAPTCHA_KEY:-}" ] && printf 'TWOCAPTCHA_KEY=%s\n' "$TWOCAPTCHA_KEY"
} > .env.local

if [ ! -d node_modules ]; then
  echo "→ Installing dependencies (first run only)…"
  npm install --no-audit --no-fund
fi

# --- Pick a port (3000 by default; auto-bump if something else already holds it,
#     e.g. another Next.js dev server — we never kill other people's processes). ---
PORT="${PORT:-3000}"
port_free() { ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
if ! port_free "$PORT"; then
  echo "→ Port $PORT is already in use (another dev server?). Finding a free port…"
  for p in 3001 3002 3003 3004 3005; do port_free "$p" && { PORT="$p"; break; }; done
fi
URL="http://127.0.0.1:$PORT"

echo
echo "────────────────────────────────────────────────────────────"
echo "  Suno sidecar → $URL   (Ctrl-C to stop; leave it running)"
if [ "$PORT" != "3000" ]; then
  echo "  ⚠  Not the default port. In Gosan → Settings, set the"
  echo "     'Suno sidecar URL' to:  $URL"
fi
echo "────────────────────────────────────────────────────────────"
echo
npm run dev -- -p "$PORT"
