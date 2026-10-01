#!/bin/bash
# Build DevSweep promo video: frames (60fps) + soundtrack.wav -> MP4 masters
set -euo pipefail
cd "$(dirname "$0")"

FPS=60
OUT_LANDSCAPE="devsweep-promo-16x9-1080p.mp4"

[ -d frames ] || { echo "frames/ missing — run: node render.js"; exit 1; }
[ -f soundtrack.wav ] || node soundtrack.js

# 1080p master (landscape)
ffmpeg -y -framerate $FPS -i frames/f%05d.png -i soundtrack.wav \
  -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -r $FPS \
  -c:a aac -b:a 192k -shortest -movflags +faststart \
  "$OUT_LANDSCAPE"

echo "-- $OUT_LANDSCAPE --"
ffprobe -v error -show_entries format=duration,size -show_entries stream=width,height,codec_name -of default=nw=1 "$OUT_LANDSCAPE"
