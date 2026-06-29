#!/usr/bin/env bash
# Headless tester for the Music.ai API — list your workflows, or run one on a file.
# Your key never goes in chat: export it locally first.
#
#   export MUSICAI_API_KEY=your-key-here
#   tools/musicai.sh workflows                     # list your workflow slugs
#   tools/musicai.sh run <slug> path/to/audio.wav  # upload → job → poll → result
#
set -euo pipefail
BASE="https://api.music.ai/v1"
: "${MUSICAI_API_KEY:?Set MUSICAI_API_KEY first (do NOT paste it in chat)}"
AUTH=(-H "Authorization: $MUSICAI_API_KEY")

have_jq() { command -v jq >/dev/null 2>&1; }

case "${1:-workflows}" in
  workflows)
    echo "Your Music.ai workflows (slug — name):"
    body=$(curl -s "${AUTH[@]}" "$BASE/workflow")
    if have_jq; then
      echo "$body" | jq -r '(.workflows // .data // .) | .[]? | "  \(.slug)\t— \(.name)"' 2>/dev/null \
        || { echo "(raw response — look for \"slug\" values:)"; echo "$body" | jq . 2>/dev/null || echo "$body"; }
    else
      echo "(install jq for pretty output — raw response below)"; echo "$body"
    fi
    ;;

  run)
    slug="${2:?usage: musicai.sh run <workflow-slug> <audio-file>}"
    file="${3:?usage: musicai.sh run <workflow-slug> <audio-file>}"
    [ -f "$file" ] || { echo "No such file: $file"; exit 1; }
    have_jq || { echo "This command needs jq (brew install jq)."; exit 1; }

    echo "1/4 requesting upload URL…"
    urls=$(curl -s "${AUTH[@]}" "$BASE/upload")
    up=$(echo "$urls" | jq -r '.uploadUrl // empty')
    down=$(echo "$urls" | jq -r '.downloadUrl // empty')
    [ -n "$up" ] && [ -n "$down" ] || { echo "unexpected /upload response: $urls"; exit 1; }

    echo "2/4 uploading $file…"
    curl -s -X PUT --upload-file "$file" "$up" >/dev/null

    echo "3/4 creating job ($slug)…"
    job=$(curl -s "${AUTH[@]}" -H "Content-Type: application/json" \
      -d "{\"name\":\"gosan-test\",\"workflow\":\"$slug\",\"params\":{\"inputUrl\":\"$down\"}}" \
      "$BASE/job")
    id=$(echo "$job" | jq -r '.id // empty')
    [ -n "$id" ] || { echo "no job id (check the slug). response: $job"; exit 1; }
    echo "    job id: $id"

    echo "4/4 polling…"
    while true; do
      sleep 4
      st=$(curl -s "${AUTH[@]}" "$BASE/job/$id")
      status=$(echo "$st" | jq -r '.status // "?"')
      echo "    $status"
      case "$status" in
        SUCCEEDED) echo "RESULT (output names → URLs):"; echo "$st" | jq '.result'; break ;;
        FAILED)    echo "FAILED:"; echo "$st" | jq '.error'; exit 1 ;;
      esac
    done
    ;;

  *) echo "usage: MUSICAI_API_KEY=... tools/musicai.sh [workflows | run <slug> <file>]"; exit 1 ;;
esac
