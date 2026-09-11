#!/usr/bin/env bash
# Import every .bsp in a directory into maps/imported/, skipping what is up to date.
#
#   tools/import_maps.sh                        # ../inspirations/g2gfast -> maps/imported
#   tools/import_maps.sh <src-dir> [out-dir]
#   tools/import_maps.sh --prune                # also delete imports whose .bsp is gone
#   tools/import_maps.sh --force                # re-import everything
#
# This is the "drop a map in" half. The other half is that nothing keeps a list:
# G2GMapCatalogue scans maps/imported/ at boot, and `maps_reload` on a running server
# rescans it, so a map appears by existing and disappears by not existing.
#
# It re-runs `godot --import` at the end and NOT once per map, because the PNGs each
# import writes are only usable as textures after Godot has converted them -- and
# because --import over a project with two maps in it costs the same as over one.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="" ; out="$here/maps/imported" ; force=0 ; prune=0

for arg in "$@"; do
    case "$arg" in
        --force) force=1 ;;
        --prune) prune=1 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) if [ -z "$src" ]; then src="$arg"; else out="$arg"; fi ;;
    esac
done
[ -z "$src" ] && src="$here/../inspirations/g2gfast"

if [ ! -d "$src" ]; then
    echo "no such directory: $src" >&2
    echo "put .bsp files there, or pass a directory" >&2
    exit 1
fi

godot_bin="${GODOT:-godot}"
command -v "$godot_bin" >/dev/null || { echo "godot not on PATH (set GODOT=)" >&2; exit 1; }

mkdir -p "$out"
imported=0 ; skipped=0 ; failed=0 ; removed=0
declare -A wanted

shopt -s nullglob nocaseglob
for bsp in "$src"/*.bsp; do
    id="$(basename "$bsp" | sed 's/\.[Bb][Ss][Pp]$//' | tr '[:upper:]' '[:lower:]')"
    wanted["$id"]=1
    manifest="$out/$id/$id.json"
    # Up to date when the manifest exists and is newer than the .bsp. Re-importing a
    # map nobody has touched is 4 seconds and 12 MB of writes for no change.
    if [ "$force" -eq 0 ] && [ -f "$manifest" ] && [ "$manifest" -nt "$bsp" ]; then
        echo "  up to date  $id"
        skipped=$((skipped + 1))
        continue
    fi
    echo "  importing   $id"
    if python3 "$here/tools/bsp_import.py" "$bsp" "$out" --id "$id" > /tmp/bsp_import_$$.log 2>&1; then
        sed 's/^/      /' /tmp/bsp_import_$$.log | tail -n +2
        imported=$((imported + 1))
    else
        echo "  FAILED      $id" >&2
        sed 's/^/      /' /tmp/bsp_import_$$.log >&2
        failed=$((failed + 1))
    fi
    rm -f /tmp/bsp_import_$$.log
done
shopt -u nullglob nocaseglob

if [ "$prune" -eq 1 ]; then
    for dir in "$out"/*/; do
        [ -d "$dir" ] || continue
        id="$(basename "$dir")"
        if [ -z "${wanted[$id]:-}" ]; then
            echo "  removing    $id (no .bsp in $src)"
            rm -rf "$dir"
            removed=$((removed + 1))
        fi
    done
fi

# A zone file for a map nobody has is the stale-list shape this tree has now hit in
# setup.sh, tools/check.sh, package_check.sh and both bootstrap scripts. It is not an
# error -- somebody may be about to drop the .bsp in -- but it is worth saying, because
# the alternative is a file that describes a finish line for a map that is not there.
for zf in "$here"/maps/zones/*.json; do
    [ -e "$zf" ] || continue
    zid="$(basename "$zf" .json)"
    [ -n "${wanted[$zid]:-}" ] || echo "  note: maps/zones/$zid.json describes a map with no .bsp in $src"
done

echo
echo "$imported imported, $skipped up to date, $removed removed, $failed failed"

if [ "$imported" -gt 0 ] || [ "$removed" -gt 0 ]; then
    echo "running godot --import so the textures become usable"
    timeout 900 "$godot_bin" --headless --path "$here" --import >/dev/null 2>&1
    echo "done. maps/imported now holds:"
    for dir in "$out"/*/; do [ -d "$dir" ] && echo "  $(basename "$dir")"; done
fi

exit $([ "$failed" -gt 0 ] && echo 1 || echo 0)
