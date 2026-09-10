#!/usr/bin/env bash
# Render an imported map to screenshots/<id>_*.png so a person can look at it.
#
#   tools/bsp_preview.sh                       # every imported map, from its spawn
#   tools/bsp_preview.sh surf_kitsune          # one, from its spawn
#   tools/bsp_preview.sh surf_kitsune orbit    # one, orbiting the whole map
#   tools/bsp_preview.sh surf_kitsune spawn 6  # six angles instead of four
#
# `tools/bsp_preview.gd` has named this script since it was written and it did not
# exist, so the one thing in this repository whose bugs are invisible to every
# assertion available had no one-line way to look at it. Four of the bugs in this
# family's own list were found by looking at a picture.
#
# xvfb-run because this needs a rendering context and the machines this runs on have
# no display. `--headless` is NOT a substitute: it gives a null renderer and saves a
# frame of nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

ids=()
if [ $# -gt 0 ] && [ -n "${1:-}" ]; then
    ids=("$1"); shift
else
    # No list anywhere: whatever is on the disk, which is how the game finds them too.
    for d in maps/imported/*/; do
        id="$(basename "$d")"
        [ -f "$d/$id.json" ] && ids+=("$id")
    done
fi
view="${1:-spawn}" ; shots="${2:-4}"

for id in "${ids[@]}"; do
    echo "  rendering $id ($view)"
    xvfb-run -a godot --path . --resolution 1600x900 \
        tools/bsp_preview.tscn -- "$id" "screenshots/${id}_${view}.png" "$shots" "$view" \
        2>&1 | grep -E "^\[preview\]" || true
done
echo "screenshots/ now holds:"
ls -1 screenshots/ | sed 's/^/  /'
