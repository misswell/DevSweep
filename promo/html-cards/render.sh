#!/bin/zsh

set -euo pipefail

cards_root="${0:A:h}"
exports_dir="$cards_root/exports"
chrome_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
port="${DEVSWEEP_CARDS_PORT:-4174}"

mkdir -p "$exports_dir"
server_log=$(mktemp /tmp/devsweep-html-cards-server.XXXXXX)
python3 -m http.server "$port" --directory "$cards_root" >"$server_log" 2>&1 &
server_pid=$!

cleanup() {
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

curl --fail --silent --show-error --retry 8 --retry-connrefused --retry-delay 1 \
  "http://127.0.0.1:$port/cards.html?card=scan" >/dev/null

for card in scan coverage safety; do
  output="$exports_dir/devsweep-card-$card.png"
  profile_dir=$(mktemp -d "/tmp/devsweep-html-cards-$card.XXXXXX")

  "$chrome_path" \
    --headless --no-sandbox --disable-gpu --disable-extensions \
    --disable-background-networking --hide-scrollbars \
    --force-device-scale-factor=1 --window-size=1080,1350 \
    --run-all-compositor-stages-before-draw --virtual-time-budget=1200 \
    --user-data-dir="$profile_dir" \
    --screenshot="$output" \
    "http://127.0.0.1:$port/cards.html?card=$card" >/dev/null 2>&1 &
  chrome_pid=$!

  for attempt in {1..15}; do
    [[ -s "$output" ]] && break
    sleep 1
  done

  kill -TERM "$chrome_pid" 2>/dev/null || true
  wait "$chrome_pid" 2>/dev/null || true
  [[ -s "$output" ]] || { print -u2 "Failed to render $card"; exit 1; }
done

file "$exports_dir"/*.png
