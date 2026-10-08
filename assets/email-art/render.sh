#!/usr/bin/env bash
# Rasterizes the email banners (SVG source) to the PNGs the emails link to.
# Email clients don't render SVG, so the PNGs are committed under
# priv/static/images/email/. Needs Google Chrome (headless).
#
#   assets/email-art/render.sh
set -euo pipefail

cd "$(dirname "$0")"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
out="../../priv/static/images/email"
mkdir -p "$out"

for svg in hero-*.svg; do
  name="${svg%.svg}"
  "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --window-size=600,240 \
    --screenshot="$PWD/$out/$name.png" "file://$PWD/$svg" >/dev/null 2>&1
  echo "rendered $out/$name.png"
done
