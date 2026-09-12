#!/usr/bin/env bash
# Renders this game's HUD to screenshots/ so a person can look at it.
#
#   tools/screenshot_hud.sh
#
# The map half is tools/bsp_preview.sh. This is the other half, and until now this was
# the only game in the family with no way to look at its own interface at all.
#
# xvfb-run because this needs a rendering context and the machines this runs on have no
# display. `--headless` is NOT a substitute: it gives a null renderer and a 64 x 64
# viewport, and every frame it saves is empty — which is worse than no screenshot
# because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
exec xvfb-run -a godot --path . --resolution 1600x900 --script tools/screenshot_hud.gd
