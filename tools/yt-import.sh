#!/usr/bin/env bash
# Download a YouTube (or other yt-dlp-supported) URL's audio for Gosan.
# Saves an .m4a to ~/Music/Gosan and reveals it in Finder — drag it onto a track.
# For personal / reference use — respect copyright.
#
#   tools/yt-import.sh "https://www.youtube.com/watch?v=..."
#
set -euo pipefail
URL="${1:?usage: tools/yt-import.sh <youtube-url>}"
command -v yt-dlp >/dev/null || { echo "yt-dlp not found — install: brew install yt-dlp"; exit 1; }

OUT="$HOME/Music/Gosan"
mkdir -p "$OUT"
echo "→ Downloading audio…"
FILE="$(yt-dlp -f 'bestaudio[ext=m4a]/bestaudio' --no-playlist --no-progress \
  -o "$OUT/%(title)s.%(ext)s" --print after_move:filepath "$URL")"
echo "✓ Saved: $FILE"
open -R "$FILE" 2>/dev/null || true
