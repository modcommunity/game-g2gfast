#!/usr/bin/env python3
"""Turn a Source .bsp into an importable g2gfast map: mesh, textures, baked light, zones.

    tools/bsp_import.py ../inspirations/g2gfast/surf_kitsune.bsp maps/imported --id surf_kitsune

Writes into <out>/<id>/:

    <id>.bin              vertex and index data, one block per material
    <id>.json             the manifest: surfaces, materials, zones, spawns
    <id>_lightmap.png     the map's own baked lighting, packed into one atlas
    textures/*.png        every texture the .bsp carried in its pakfile

and generates `maps/<id>.gd`, a [G2GMap] subclass that builds an [ArrayMesh] from
those at load and returns the timer zones.

[b]Why a mesh binary and not glTF.[/b] The baked lighting needs a second UV set,
and the route through glTF into Godot's importer decides for you what a second UV
set means -- it lands on `ao_texture` (greyscale, so the coloured neon that is this
map's entire character goes grey) or on `emission` (additive, so it washes out).
Building the [ArrayMesh] in [method ArrayMesh.add_surface_from_arrays] costs about
twenty lines, keeps ARRAY_TEX_UV2 as what it is, and is the shape every other map in
this repository already has: geometry made in code.

[b]Units.[/b] Positions are in genre units, Godot axes. See tools/bsp_read.py.
"""

import argparse
import collections
import io
import json
import math
import os
import re
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bsp_read import Bsp, SKIP_MASK, clean_material, to_godot, LUMP_ENTITIES  # noqa: E402
import vtf  # noqa: E402

LUMP_LIGHTING, LUMP_PAKFILE, LUMP_PLANES = 8, 40, 1
ATLAS_W = 1024
LM_PAD = 1

# Where the six g2gfast roles come from. A material's name is the only description of
# intent a compiled .bsp still carries -- the brush entity that knew "this is the start
# platform" is gone -- and in this genre the names are conventional enough to use:
# every surf map on earth puts its ride surface on some variant of `concretefloor039a`.
ROLE_RULES = [
    (r"ramp|concretefloor039a|bathroom_tile_floor_lg|neon_b\b", "RAMP"),
    (r"^tools/|nodraw|toolsblack", "PLATFORM"),
    (r"sky|light|white001|neon", "PLATFORM"),
    (r"grid|glass", "PLATFORM"),
    (r"rock|sand|grass|nature|dirt|lava", "FLOOR"),
]


def role_for(material):
    for pattern, role in ROLE_RULES:
        if re.search(pattern, material, re.I):
            return role
    return "FLOOR"


# ---------------------------------------------------------------- pakfile ----
def read_pak(bsp):
    off, ln, _ = bsp.dir[LUMP_PAKFILE]
    if not ln:
        return {}
    z = zipfile.ZipFile(io.BytesIO(bsp.d[off:off + ln]))
    return {n.lower(): z.read(n) for n in z.namelist()}


def vmt_basetexture(src):
    """The $basetexture out of a VMT.

    A patch material (`Patch { include ... replace { $basetexture x } }`) names its
    base inside a nested block, so a first-match regex over the whole file is right
    and walking only the top level is not.
    """
    txt = src.decode("ascii", "replace")
    txt = re.sub(r"//[^\n]*", "", txt)
    m = re.search(r'"?\$basetexture"?\s+"?([^"\s]+)"?', txt, re.I)
    base = m.group(1).replace("\\", "/").lower().strip() if m else None
    translucent = bool(re.search(r'"?\$(translucent|alphatest)"?\s+"?1', txt, re.I))
    return base, translucent


def extract_textures(pak, materials, tex_dir):
    """Decode every referenced texture the map carried with it.

    Returns {material: (png filename or None, translucent)}. A material whose texture
    lives in the game's own VPKs -- `concrete/concretefloor039a` is CS:S stock -- is
    not an error and not a guess: it comes back None and the map script paints it with
    the g2gfast role colour instead.
    """
    os.makedirs(tex_dir, exist_ok=True)
    out, written = {}, {}
    for mat in materials:
        vmt = pak.get("materials/%s.vmt" % mat)
        if vmt is None:
            out[mat] = (None, False)
            continue
        base, translucent = vmt_basetexture(vmt)
        if not base:
            out[mat] = (None, translucent)
            continue
        raw = pak.get("materials/%s.vtf" % base)
        if raw is None:
            out[mat] = (None, translucent)
            continue
        if base in written:
            out[mat] = (written[base], translucent)
            continue
        name = base.replace("/", "_") + ".png"
        try:
            w, h, px = vtf.decode(raw)
        except ValueError:
            out[mat] = (None, translucent)      # HDR cubemaps and other oddities
            continue
        opaque = not translucent and vtf.is_opaque(px)
        vtf.write_png(os.path.join(tex_dir, name), w, h, px, opaque=opaque)
        written[base] = name
        out[mat] = (name, translucent and not opaque)
    return out


# --------------------------------------------------------------- lightmap ----
def build_lightmap(bsp, faces, path):
    """Pack every lit face's luxels into one atlas and return its placements.

    Source stores lighting as RGBE -- three bytes and a shared signed exponent -- so a
    luxel can be far brighter than white, which is the point: it is light, not a
    colour. It is tone-mapped down here rather than in the shader so the atlas is an
    ordinary sRGB PNG that Godot imports with no special handling.
    """
    light = bsp._lump(LUMP_LIGHTING)
    lit = [f for f in faces if f[9] >= 0 and (f[9] + 4) <= len(light)]
    lit.sort(key=lambda f: -(f[14] + 1))

    # A 2x2 white patch first, so unlit faces have somewhere to point. Without it they
    # sample whatever face happens to sit at the atlas origin and wear its lighting.
    x, y, shelf = 4, 0, 4
    place = {}
    for f in lit:
        w, h = f[13] + 1, f[14] + 1
        if x + w + LM_PAD * 2 > ATLAS_W:
            x, y, shelf = 0, y + shelf, 0
        place[id(f)] = (x + LM_PAD, y + LM_PAD)
        x += w + LM_PAD * 2
        shelf = max(shelf, h + LM_PAD * 2)
    height = max(4, y + shelf)
    height = 1 << (height - 1).bit_length()

    atlas = bytearray(ATLAS_W * height * 4)
    for i in range(3, len(atlas), 4):
        atlas[i] = 255
    for j in range(4):                                   # the white patch
        for i in range(4):
            p = (j * ATLAS_W + i) * 4
            atlas[p] = atlas[p + 1] = atlas[p + 2] = 255

    inv_gamma = 1.0 / 2.2
    for f in lit:
        px, py = place[id(f)]
        w, h = f[13] + 1, f[14] + 1
        o = f[9]
        for j in range(h):
            row = (py + j) * ATLAS_W
            for i in range(w):
                q = o + (j * w + i) * 4
                if q + 3 >= len(light):
                    continue
                e = light[q + 3]
                s = (2.0 ** (e - 256 if e > 127 else e)) / 255.0
                p = (row + px + i) * 4
                for k in range(3):
                    v = min(1.0, light[q + k] * s)
                    atlas[p + k] = int(255.0 * (v ** inv_gamma))
    vtf.write_png(path, ATLAS_W, height, bytes(atlas), opaque=True)
    return place, ATLAS_W, height


# ----------------------------------------------------------------- meshing ----
def face_normal(bsp, f):
    n = bsp.planes[f[0]][:3]
    return (-n[0], -n[1], -n[2]) if f[1] else n


def build_mesh(bsp, out_bin, lm_place, lm_w, lm_h):
    """One vertex block and one index block per material."""
    planes = bsp.planes
    groups = collections.defaultdict(lambda: ([], []))     # mat -> (verts, indices)
    dedupe = collections.defaultdict(dict)

    def emit(mat, pos_src, nrm_src, uv, uv2):
        verts, _ = groups[mat]
        key = (round(pos_src[0], 2), round(pos_src[1], 2), round(pos_src[2], 2),
               round(nrm_src[0], 3), round(nrm_src[1], 3), round(nrm_src[2], 3),
               round(uv[0], 4), round(uv[1], 4), round(uv2[0], 5), round(uv2[1], 5))
        d = dedupe[mat]
        if key in d:
            return d[key]
        g, gn = to_godot(pos_src), to_godot(nrm_src)
        verts.append((g, gn, uv, uv2))
        d[key] = len(verts) - 1
        return len(verts) - 1

    white = (2.0 / lm_w, 2.0 / lm_h)

    for f in bsp.model_faces(0):
        mat_raw, flags = bsp.face_material(f)
        if flags & SKIP_MASK:
            continue
        mat = clean_material(mat_raw)
        ti = bsp.texinfo[f[5]]
        tw, th = 1, 1
        td = int(ti[17])
        if 0 <= td < len(bsp.texdata):
            tw, th = max(1, bsp.texdata[td][4]), max(1, bsp.texdata[td][5])

        def uv_of(p):
            u = (p[0] * ti[0] + p[1] * ti[1] + p[2] * ti[2] + ti[3]) / tw
            v = (p[0] * ti[4] + p[1] * ti[5] + p[2] * ti[6] + ti[7]) / th
            return (u, v)

        pl = lm_place.get(id(f))

        def uv2_of(p):
            if pl is None:
                return white
            lu = p[0] * ti[8] + p[1] * ti[9] + p[2] * ti[10] + ti[11] - f[11]
            lv = p[0] * ti[12] + p[1] * ti[13] + p[2] * ti[14] + ti[15] - f[12]
            lu = min(max(lu, 0.0), float(f[13]))
            lv = min(max(lv, 0.0), float(f[14]))
            return ((pl[0] + lu + 0.5) / lm_w, (pl[1] + lv + 0.5) / lm_h)

        _, idx = groups[mat]
        if f[6] >= 0:
            tris = bsp.displacement_tris(f)
            # Displacements are terrain: average the normals over the grid so a
            # rock face is not a field of flat triangles. Brush faces below keep
            # their exact plane normal, because a surf ramp's edge IS sharp.
            acc = collections.defaultdict(lambda: [0.0, 0.0, 0.0])
            for t in tris:
                u = [t[1][i] - t[0][i] for i in range(3)]
                v = [t[2][i] - t[0][i] for i in range(3)]
                n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2],
                     u[0] * v[1] - u[1] * v[0]]
                for p in t:
                    k = (round(p[0], 2), round(p[1], 2), round(p[2], 2))
                    for i in range(3):
                        acc[k][i] += n[i]
            for t in tris:
                for p in t:
                    k = (round(p[0], 2), round(p[1], 2), round(p[2], 2))
                    n = acc[k]
                    ln = math.sqrt(sum(c * c for c in n)) or 1.0
                    idx.append(emit(mat, p, [c / ln for c in n], uv_of(p), uv2_of(p)))
        else:
            pts = bsp.face_points(f)
            if len(pts) < 3:
                continue
            n = face_normal(bsp, f)
            ring = [emit(mat, p, n, uv_of(p), uv2_of(p)) for p in pts]
            for k in range(1, len(ring) - 1):
                # Source winds its faces the other way round from Godot's front face.
                idx.extend((ring[0], ring[k + 1], ring[k]))

    surfaces, blob = [], bytearray()
    for mat in sorted(groups):
        verts, idx = groups[mat]
        if not idx:
            continue
        voff = len(blob)
        for g, gn, uv, uv2 in verts:
            blob += struct.pack("<10f", g[0], g[1], g[2], gn[0], gn[1], gn[2],
                                uv[0], uv[1], uv2[0], uv2[1])
        ioff = len(blob)
        for i in idx:
            blob += struct.pack("<I", i)
        surfaces.append({"material": mat, "role": role_for(mat),
                         "vertex_offset": voff, "vertex_count": len(verts),
                         "index_offset": ioff, "index_count": len(idx)})
    open(out_bin, "wb").write(bytes(blob))
    return surfaces


# -------------------------------------------------------------------- zones ---
def classify_zones(bsp):
    """Spawns, and the volumes a timer cares about.

    [b]START and END are not automatable and are not guessed here.[/b] A CS:S surf map
    has no convention for them: surf_kitsune drives its stages with
    `OnTrigger !activator,AddOutput,targetname X` and a filter chain, which is a
    program, not a label. What IS reliable is `trigger_teleport` -- the volume that
    catches a player who fell off the ride -- and that maps exactly onto
    [code]DotTimerZone.Kind.RESPAWN[/code], which is most of the value.
    """
    spawns, respawn, push, other = [], [], [], []
    for e in bsp.entities:
        cls = e.get("classname", "")
        origin = None
        if "origin" in e:
            try:
                origin = list(to_godot([float(x) for x in e["origin"].split()]))
            except ValueError:
                pass
        box = None
        model = e.get("model", "")
        if model.startswith("*"):
            mi = int(model[1:])
            if mi < len(bsp.models):
                lo, hi = bsp.model_bounds(mi)
                a, b = to_godot(lo), to_godot(hi)
                box = ([min(a[i], b[i]) for i in range(3)],
                       [max(a[i], b[i]) for i in range(3)])
        if cls in ("info_player_terrorist", "info_player_counterterrorist",
                   "info_player_start") and origin:
            yaw = 0.0
            if "angles" in e:
                try:
                    yaw = float(e["angles"].split()[1])
                except (ValueError, IndexError):
                    pass
            spawns.append({"origin": origin, "yaw": yaw})
        elif cls == "trigger_teleport" and box:
            respawn.append({"min": box[0], "max": box[1]})
        elif cls == "trigger_push" and box:
            push.append({"min": box[0], "max": box[1]})
        elif cls in ("trigger_multiple", "trigger_once") and box:
            other.append({"min": box[0], "max": box[1],
                          "targetname": e.get("targetname", ""),
                          "filtername": e.get("filtername", "")})
    return spawns, respawn, push, other


def pick_spawn(spawns):
    """The spawn a map should start you at.

    A CS:S map has up to 144 of them in two team blocks. The lowest-numbered
    is arbitrary; the CENTRE of the biggest cluster is where the mapper put the start
    pad, and taking the mean over all of them is wrong the moment a map spawns two
    teams at opposite ends.
    """
    if not spawns:
        return {"origin": [0.0, 64.0, 0.0], "yaw": 0.0}
    best, bestn = spawns[0], 0
    for s in spawns:
        n = sum(1 for o in spawns
                if sum((o["origin"][i] - s["origin"][i]) ** 2 for i in range(3)) < 512 ** 2)
        if n > bestn:
            best, bestn = s, n
    return best


# ------------------------------------------------------------- map scripts ---
MAP_GD = """extends G2GBspMap

## `{id}` -- imported from `{source}` by tools/bsp_import.py.
##
## Everything that makes this map is in `imported/{id}/`: the mesh binary, the
## manifest, the textures the .bsp carried and the lighting its compiler baked.
## [G2GBspMap] builds them. Regenerate rather than edit:
##
##     tools/bsp_import.py <the .bsp> maps/imported --id {id}


func _init() -> void:
	manifest_path = "res://maps/imported/{id}/{id}.json"
"""

MAP_TSCN = """[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://maps/imported/{id}/{id}.gd" id="1_map"]

[node name="Map" type="Node3D"]
script = ExtResource("1_map")
"""


def write_map_scripts(map_dir, map_id, source):
    """The four-line subclass and its scene, inside the map's own directory.

    Generated rather than hand-kept because the only thing in them that varies is the
    id, and this tree has been bitten four times by a second copy of something going
    stale. Regenerating is always correct; editing is always a mistake.

    They live beside the data rather than beside the hand-written maps so that ignoring
    an imported map is one line and not a list of names -- the same bug, one level up.
    """
    gd = os.path.join(map_dir, map_id + ".gd")
    tscn = os.path.join(map_dir, map_id + ".tscn")
    with open(gd, "w") as fh:
        fh.write(MAP_GD.format(id=map_id, source=source))
    with open(tscn, "w") as fh:
        fh.write(MAP_TSCN.format(id=map_id))
    return gd, tscn


# ------------------------------------------------------------------- driver ---
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("bsp")
    ap.add_argument("out_dir")
    ap.add_argument("--id", default=None, help="map id (default: the file stem)")
    ap.add_argument("--tier", type=int, default=3)
    a = ap.parse_args(argv)

    map_id = (a.id or os.path.splitext(os.path.basename(a.bsp))[0]).lower()
    d = os.path.join(a.out_dir, map_id)
    os.makedirs(d, exist_ok=True)

    bsp = Bsp(a.bsp).load()
    faces = [f for f in bsp.model_faces(0) if not (bsp.face_material(f)[1] & SKIP_MASK)]

    lm_path = os.path.join(d, map_id + "_lightmap.png")
    place, lm_w, lm_h = build_lightmap(bsp, faces, lm_path)
    surfaces = build_mesh(bsp, os.path.join(d, map_id + ".bin"), place, lm_w, lm_h)

    pak = read_pak(bsp)
    tex = extract_textures(pak, [s["material"] for s in surfaces], os.path.join(d, "textures"))
    for s in surfaces:
        png, translucent = tex.get(s["material"], (None, False))
        s["texture"] = png
        s["translucent"] = translucent

    spawns, respawn, push, other = classify_zones(bsp)
    lo, hi = bsp.model_bounds(0)
    manifest = {
        "id": map_id,
        "source": os.path.basename(a.bsp),
        "units": "genre units (Source units), Godot axes; x metres = x * 0.01905",
        "tier": a.tier,
        "bounds": {"min": list(to_godot(lo)), "max": list(to_godot(hi))},
        "lightmap": {"file": os.path.basename(lm_path), "width": lm_w, "height": lm_h},
        "surfaces": surfaces,
        "spawn": pick_spawn(spawns),
        "spawns": spawns,
        "respawn_volumes": respawn,
        "push_volumes": push,
        "trigger_volumes": other,
    }
    with open(os.path.join(d, map_id + ".json"), "w") as fh:
        json.dump(manifest, fh, indent=1)

    tris = sum(s["index_count"] for s in surfaces) // 3
    textured = sum(s["index_count"] for s in surfaces if s["texture"]) // 3
    print("%s -> %s" % (os.path.basename(a.bsp), d))
    print("  %d surfaces, %d tris (%d%% textured from the pakfile)"
          % (len(surfaces), tris, textured * 100 // max(1, tris)))
    print("  lightmap %dx%d, %d lit faces" % (lm_w, lm_h, len(place)))
    print("  %d spawns, %d respawn volumes, %d push, %d other triggers"
          % (len(spawns), len(respawn), len(push), len(other)))
    print("  start spawn at %s units" % [round(v) for v in manifest["spawn"]["origin"]])

    gd, tscn = write_map_scripts(d, map_id, os.path.basename(a.bsp))
    print("  wrote %s and %s" % (os.path.basename(gd), os.path.basename(tscn)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
