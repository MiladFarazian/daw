#!/usr/bin/env bash
# One command to run a local Suno sidecar so Gosan can generate with one click
# (the green dot in the Generate panel). Needs Node.js + git.
#
# Your Suno cookie: log in at suno.com → DevTools (⌥⌘I) → Network → click any request
# to studio-api.suno.ai → copy the full "cookie" request header. Then:
#
#   SUNO_COOKIE='paste-cookie-here' tools/suno-sidecar.sh
#
# Leave it running. In Gosan → Generate, the sidecar dot turns green.
# (If Suno's bot check blocks it, just use "Open in Suno (manual)" instead.)
set -euo pipefail

DIR="${SUNO_SIDECAR_DIR:-$HOME/.gosan/suno-api}"
: "${SUNO_COOKIE:?Set SUNO_COOKIE first — copy it from suno.com DevTools (do NOT paste it in chat)}"
command -v git >/dev/null  || { echo "git is required."; exit 1; }
command -v node >/dev/null || { echo "Node.js is required (brew install node)."; exit 1; }

if [ ! -d "$DIR/.git" ]; then
  echo "→ Cloning gcui-art/suno-api into $DIR"
  git clone --depth 1 https://github.com/gcui-art/suno-api "$DIR"
fi
cd "$DIR"

# Next.js reads .env.local; write the cookie there (never committed).
printf 'SUNO_COOKIE=%s\nBROWSER=chromium\nBROWSER_GHOST_CURSOR=false\n' "$SUNO_COOKIE" > .env.local

if [ ! -d node_modules ]; then
  echo "→ Installing dependencies (first run only)…"
  npm install
fi

echo "→ Starting Suno sidecar on http://localhost:3000  (Ctrl-C to stop)"
npm run dev
