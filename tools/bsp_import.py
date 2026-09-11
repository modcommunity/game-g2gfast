#!/usr/bin/env python3
"""Turn a Source .bsp into an importable g2gfast map: mesh, textures, baked light, zones.

    tools/bsp_import.py ../inspirations/g2gfast/surf_kitsune.bsp maps/imported --id surf_kitsune

Writes into <out>/<id>/:

    <id>.bin              vertex and index data, one block per material
    <id>.json             the manifest: surfaces, materials, zones, spawns
    <id>_lightmap.png     the map's own baked lighting, packed into one atlas
    textures/*.png        every texture the .bsp carried in its pakfile

That directory IS the map. There is no scene and no script per map: every imported map
is the one `maps/imported_map.tscn` that ships inside the build, pointed at a different
manifest. A generated `<id>.tscn` cannot work for a map that arrives after the export --
`res://` is a read-only PCK in a shipped build -- so a map is data at a path, and the
paths the game searches include ones outside `res://` for exactly that reason.

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
from bsp_read import (Bsp, SKIP_MASK, clean_material, to_godot, yaw_to_godot,  # noqa: E402
                      LUMP_ENTITIES)
import vtf  # noqa: E402

LUMP_LIGHTING, LUMP_PAKFILE, LUMP_PLANES = 8, 40, 1
ATLAS_W = 1024
LM_PAD = 1

# The least a zone volume may measure on any axis, in genre units.
#
# [b]Source sweeps its trigger tests and dot-timer samples a point per tick.[/b] A
# `trigger_teleport` in a surf map is the pit, and a mapper draws it as a 16-unit
# plane because Source asks "did the player's path cross this". dot-timer's index asks
# `contains(point)` once a tick, so at 3500 u/s and 128 Hz -- 27 units of travel per
# tick -- a falling player steps straight over a 16-unit plane and keeps falling for
# ever, which is precisely the bug dot-timer's RESPAWN zones exist to prevent.
#
# The plane is therefore inflated into a slab centred on it. Centred, and not extended
# downward: downward is right for a pit and wrong for a boundary trigger above the
# play space, and a slab centred on the original plane is the honest approximation of
# the swept test Source was doing. 192 units is seven ticks of travel at the genre's
# ceiling speed.
MIN_ZONE_THICKNESS = 192.0

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
def inflate(lo, hi, minimum):
    """A box grown about its own centre until no axis is thinner than `minimum`."""
    lo, hi = list(lo), list(hi)
    grown = False
    for i in range(3):
        span = hi[i] - lo[i]
        if span < minimum:
            centre = (lo[i] + hi[i]) * 0.5
            lo[i], hi[i] = centre - minimum * 0.5, centre + minimum * 0.5
            grown = True
    return lo, hi, grown


def entity_origin(e):
    try:
        return [float(x) for x in e.get("origin", "0 0 0").split()][:3]
    except ValueError:
        return [0.0, 0.0, 0.0]


def entity_yaw(e):
    try:
        return float(e["angles"].split()[1])
    except (KeyError, ValueError, IndexError):
        return 0.0


def brush_box(bsp, e):
    """A brush entity's volume in world (Hammer) coordinates, or None.

    [b]A brush model's bounds are relative to the entity's `origin` key.[/b] vbsp
    moves a brush entity's geometry so that its origin sits at (0,0,0) and records
    where that was; the two are only the same thing for worldspawn, whose origin is
    the world's. A reader that takes the bounds alone gets every trigger in the map
    piled around the map's centre -- which is exactly what this importer did, so every
    pit volume in the two maps it had imported was drawn somewhere the player never
    goes, and caught nobody. Nothing errored: a RESPAWN volume that is never entered
    is indistinguishable from one nobody has fallen into yet.

    Confirmed against the faces rather than reasoned about: for every trigger in
    surf_kitsune the model's own vertices span exactly the model's bounds, and the
    entity's origin is the offset to where the mapper drew it.
    """
    model = e.get("model", "")
    if not model.startswith("*"):
        return None
    index = int(model[1:])
    if index >= len(bsp.models):
        return None
    lo, hi = bsp.model_bounds(index)
    o = entity_origin(e)
    return ([lo[i] + o[i] for i in range(3)], [hi[i] + o[i] for i in range(3)])


def union_box(boxes):
    lo = [min(b[0][i] for b in boxes) for i in range(3)]
    hi = [max(b[1][i] for b in boxes) for i in range(3)]
    return lo, hi


def box_contains(box, point, margin=0.0):
    return all(box[0][i] - margin <= point[i] <= box[1][i] + margin for i in range(3))


def _norm_name(name):
    return re.sub(r"^(tm_|tr_|trigger_)", "", name.strip().lower())


def zone_role(name):
    """(kind, stage number, track key) for a trigger's targetname, or None.

    [b]These maps label their own zones, and the importer used to throw the labels
    away.[/b] The comment that stood here said a CS:S surf map has no convention for
    a start and a finish. That is true of surf_kitsune, which really does drive its
    stages with a filter chain -- and false of five of the eight maps beside it, which
    carry `zone_start`, `map_end_zone`, `startzone_s4` and `tm_bonus2_endzone` in
    plain text, because they were built for a timer. Reading a label the mapper wrote
    is not guessing.

    What is still not guessed: a map with no such names gets no start and no end from
    here. It gets them from `maps/zones/<id>.json`, where somebody wrote down what
    they worked out, next to why.
    """
    n = _norm_name(name)

    m = re.match(r"^(?:startzone|start_zone|zone_start)_s(\d+)$", n)
    if m:
        return ("STAGE", int(m.group(1)), "")

    m = re.match(r"^checkpoint[_-]?(\d+)$", n)
    if m:
        # A numbered checkpoint is a split, and a split opens the section after it.
        # Stage 1 is the map's own start line, so checkpoint 1 is the start of stage 2.
        return ("STAGE", int(m.group(1)) + 1, "")

    if "checkpoint" in n:
        # A NAMED checkpoint is not a split. surf_interference's are `center`, `left`
        # and `right`: three routes through one section, of which a player takes
        # exactly one -- so numbering them would put a different set of splits on
        # every run and make the column meaningless.
        return ("CHECKPOINT", 0, "")

    if "zone" not in n:
        return None
    if "start" in n:
        kind = "START"
    elif "end" in n:
        kind = "END"
    else:
        return None

    rest = n.replace("zone", "").replace("start", "").replace("end", "")
    rest = re.sub(r"[_\s]+", "_", rest).strip("_")
    rest = re.sub(r"^(map|the)_?", "", rest).strip("_")
    return (kind, 0, rest)


def assign_tracks(keys):
    """Track key -> track number, using the map's own numbering wherever it has one.

    `bonus2` is bonus 2 because the people who play it call it that. A track the map
    names rather than numbers -- surf_beginner2's `koga`, `sagan`, `spy`, `frag` --
    gets the lowest free number in alphabetical order, which is arbitrary but stable:
    the same map imported twice numbers them the same way, and a records table keyed
    on track 3 keeps meaning the same route.
    """
    out = {"": 0}
    taken = {0}
    named = []
    for key in sorted(k for k in keys if k):
        m = re.search(r"bonus[_ ]?(\d+)", key) or re.match(r"^b(\d+)$", key)
        if m and 1 <= int(m.group(1)) <= 8:
            out[key] = int(m.group(1))
            taken.add(int(m.group(1)))
        else:
            named.append(key)
    n = 1
    for key in named:
        while n in taken:
            n += 1
        if n > 8:
            break
        out[key] = n
        taken.add(n)
    return out


class Zoner:
    """Everything the manifest's `zones` list is worked out from.

    Holds the entity lump, what each rule has claimed out of it, and the zones built
    so far. [b]Claiming matters.[/b] A trigger that is the finish line must not also
    be one of the hundred-odd pit volumes, and the only thing separating the two is
    that something already decided what it was.
    """

    def __init__(self, bsp, min_thickness=MIN_ZONE_THICKNESS):
        self.bsp = bsp
        self.min_thickness = min_thickness
        self.claimed = set()
        self.zones = []
        self.notes = []
        self.track_names = {}

    # -- reading the entity lump ------------------------------------------
    def entities(self, *classnames):
        for i, e in enumerate(self.bsp.entities):
            if i in self.claimed:
                continue
            if not classnames or e.get("classname", "") in classnames:
                yield i, e

    def destinations(self, name):
        """Every `info_teleport_destination` with that targetname, case-insensitively.

        Case-insensitively because Source is: surf_kitsune's triggers target `Red`,
        `yellow` and `WHITE` while its destinations are named `red`, `YELLOW` and
        `white`, and the game does not care.
        """
        want = name.strip().lower()
        out = []
        for e in self.bsp.entities:
            if e.get("classname", "") != "info_teleport_destination":
                continue
            if e.get("targetname", "").strip().lower() == want:
                out.append((entity_origin(e), entity_yaw(e)))
        return out

    def teleports_to(self, name):
        """Every unclaimed `trigger_teleport` aimed at that destination name."""
        want = name.strip().lower()
        return [(i, e) for i, e in self.entities("trigger_teleport")
                if e.get("target", "").strip().lower() == want]

    def named(self, name):
        """Every unclaimed brush entity with that targetname."""
        want = name.strip().lower()
        return [(i, e) for i, e in self.entities()
                if e.get("targetname", "").strip().lower() == want and brush_box(self.bsp, e)]

    # -- building zones ----------------------------------------------------
    def add(self, kind, track, box=None, number=0, destination=None, yaw=0.0, comment=""):
        zone = {"kind": kind, "track": int(track)}
        if number:
            zone["number"] = float(number)
        if box is not None:
            lo, hi, grown = inflate(box[0], box[1], self.min_thickness)
            zone["min"], zone["max"] = lo, hi
            zone["original_min"], zone["original_max"] = list(box[0]), list(box[1])
            zone["inflated"] = grown
        if destination is not None:
            zone["destination"] = list(destination)
            zone["destination_yaw"] = float(yaw)
        if comment:
            zone["comment"] = comment
        self.zones.append(zone)
        return zone

    def of_kind(self, kind, track=None):
        return [z for z in self.zones
                if z["kind"] == kind and (track is None or z["track"] == track)]

    def tracks(self):
        return sorted({z["track"] for z in self.zones})


def label_zones(z):
    """The zones the map labelled itself, from `trigger_multiple` targetnames."""
    found = []
    for i, e in z.entities("trigger_multiple", "trigger_once"):
        name = e.get("targetname", "")
        if not name:
            continue
        role = zone_role(name)
        box = brush_box(z.bsp, e)
        if role is None or box is None:
            continue
        found.append((i, e, name, role, box))

    tracks = assign_tracks({role[2] for _, _, _, role, _ in found})
    z.track_names = {str(v): (k or "main") for k, v in tracks.items()}

    # Two brushes sharing a targetname are ONE entity in Source, and a mapper uses
    # that: surf_summit's `tm_checkpoint1` is a pair, one in each of the map's two
    # mirrored lanes. Emitted as two zones they are two stage zones with the same
    # number, which `DotTimerZoneSet.problems()` refuses and is right to -- so they
    # are unioned back into the one volume the map always meant them to be.
    merged = {}
    for i, e, name, role, box in found:
        z.claimed.add(i)
        key = name.strip().lower()
        if key in merged:
            merged[key][1].append(box)
        else:
            merged[key] = (role, [box], name)

    for role, boxes, name in merged.values():
        kind, number, track_key = role
        if len(boxes) > 1:
            z.notes.append("%s is %d volumes and was unioned into one"
                           % (name, len(boxes)))
        z.add(kind, tracks.get(track_key, 0), box=union_box(boxes),
              number=number, comment=name)


def resolve_overrides(z, doc):
    """The zones a person worked out, from `maps/zones/<id>.json`.

    [b]Coordinates in that file are Hammer's, not Godot's.[/b] They are read out of
    the .bsp with the tools in this directory and typed in as they were read; the axis
    swap happens once, here, where everything else's does. A file that mixed the two
    would be a file nobody can check against the map.
    """
    for spec in doc.get("zones", []):
        kind = str(spec.get("kind", "")).upper()
        track = int(spec.get("track", 0))
        box = resolve_box(z, spec)
        dest, yaw = resolve_point(z, spec)
        if kind not in POINT_KINDS and box is None:
            raise ValueError("zone %r in the override resolves to no volume" % spec)
        if box is not None and dest is None and kind in ("STAGE", "SPAWN", "TELEPORT"):
            dest, yaw = floor_of(box), float(spec.get("destination_yaw", 0.0))
        z.add(kind, track, box=box, number=float(spec.get("number", 0)),
              destination=dest, yaw=yaw, comment=str(spec.get("note", "")))


POINT_KINDS = ("SPAWN",)


# How far above the point it names a destination puts a player, in genre units.
#
# A Source `info_teleport_destination` is at the player's feet and so is the middle of
# a zone's floor, so SOMETHING has to lift a player off it: a foot resting at exactly
# the floor's height is the state dot-fps-controller's own notes describe as never
# reporting ground again. It was 8 units, which is 15 cm, and 15 cm turns out to be
# inside the noise.
#
# Measured on Surf_Mesa, whose spawn destination sits 25 units over the platform.
# Dropped from 10168 the player lands; from 10170 the player lands; from **10169**,
# which is where an 8-unit lift put them, the player goes through the floor and keeps
# going -- and moving them one unit in x, or 320 units in y, fixes it. One point on
# one map, and it was the point the map shipped with. A capsule that starts that close
# to a triangle seam is a coin toss, so the answer is not to start there: 24 units is
# clear of the seam and still leaves a 94.5-unit player 9 units of headroom under
# Source's own minimum 128-unit ceiling.
DESTINATION_LIFT = 24.0


def floor_of(box):
    """The middle of a box's floor. Where a `!s3` puts a player."""
    return [(box[0][0] + box[1][0]) * 0.5, (box[0][1] + box[1][1]) * 0.5, box[0][2]]


def resolve_box(z, spec):
    """A volume from whichever of the override's five ways of naming one it used."""
    ways = [k for k in ("box", "named", "teleport_to", "around", "near") if k in spec]
    if len(ways) > 1:
        raise ValueError("zone %r names its volume %d ways" % (spec, len(ways)))
    if not ways:
        return None
    way = ways[0]

    if way == "box":
        lo, hi = spec["box"]
        return ([min(lo[i], hi[i]) for i in range(3)], [max(lo[i], hi[i]) for i in range(3)])

    if way == "named":
        hits = z.named(spec["named"])
        if not hits:
            raise ValueError("no brush entity is named %r" % spec["named"])
        for i, _ in hits:
            z.claimed.add(i)
        return union_box([brush_box(z.bsp, e) for _, e in hits])

    if way == "teleport_to":
        hits = z.teleports_to(spec["teleport_to"])
        if "max_horizontal" in spec:
            # A destination that is both walked to and fallen to needs telling apart:
            # surf_kitsune's `start` is reached by one door at the end of white and by
            # a pit 6144 units across in the section before it.
            limit = float(spec["max_horizontal"])
            hits = [(i, e) for i, e in hits
                    for b in [brush_box(z.bsp, e)]
                    if b and max(b[1][0] - b[0][0], b[1][1] - b[0][1]) <= limit]
        if not hits:
            raise ValueError("nothing teleports to %r" % spec["teleport_to"])
        if len(hits) > 1 and not spec.get("all", False):
            raise ValueError("%d triggers teleport to %r; say \"all\": true to mean all of them"
                             % (len(hits), spec["teleport_to"]))
        for i, _ in hits:
            z.claimed.add(i)
        return union_box([brush_box(z.bsp, e) for _, e in hits])

    if way == "around":
        around = spec["around"]
        points = resolve_points(z, around["point"])
        if not points:
            raise ValueError("nothing to build a box around in %r" % around)
        e = around.get("extents", [128.0, 128.0, 64.0])
        lo = [min(p[i] for p in points) - e[i] for i in range(3)]
        hi = [max(p[i] for p in points) + e[i] for i in range(3)]
        return lo, hi

    near = spec["near"]
    want = near["point"]
    best, best_d = None, float(near.get("within", 512.0)) ** 2
    for i, ent in z.entities(*near.get("class", "trigger_multiple").split()):
        b = brush_box(z.bsp, ent)
        if b is None:
            continue
        c = [(b[0][k] + b[1][k]) * 0.5 for k in range(3)]
        d = sum((c[k] - want[k]) ** 2 for k in range(3))
        if d <= best_d:
            best, best_d = (i, b), d
    if best is None:
        raise ValueError("no %s near %r" % (near.get("class", "trigger_multiple"), want))
    z.claimed.add(best[0])
    return best[1]


def resolve_points(z, spec):
    """A list of Hammer points from a destination name, a list of them, or a literal."""
    if isinstance(spec, str):
        return [p for p, _ in z.destinations(spec)]
    if spec and isinstance(spec[0], (int, float)):
        return [list(spec)]
    out = []
    for one in spec:
        out.extend(resolve_points(z, one))
    return out


def resolve_point(z, spec):
    """The `destination` an override gave a zone, with the yaw that came with it."""
    if "destination" not in spec:
        return None, 0.0
    want = spec["destination"]
    if isinstance(want, str):
        hits = z.destinations(want)
        if not hits:
            raise ValueError("there is no destination named %r" % want)
        return hits[0][0], float(spec.get("destination_yaw", hits[0][1]))
    return list(want), float(spec.get("destination_yaw", 0.0))


def stage_destinations(z):
    """Give every stage zone somewhere `!s<n>` can put a player.

    A stage zone with no destination resolves to the origin, which on every one of
    these maps is a point in the sky -- and nothing errors, because the request
    succeeds. Preferring a destination the mapper drew INSIDE the zone over the middle
    of the zone's own floor matters for the same reason: `failman_s4` faces down the
    map and the middle of a floor faces north.
    """
    for zone in z.zones:
        if zone["kind"] not in ("STAGE", "START", "END") or "min" not in zone:
            continue
        if "destination" in zone:
            continue
        box = (zone.get("original_min", zone["min"]), zone.get("original_max", zone["max"]))
        inside = [(p, y) for e in z.bsp.entities
                  if e.get("classname", "") == "info_teleport_destination"
                  for p, y in [(entity_origin(e), entity_yaw(e))]
                  if box_contains(box, p, 32.0)]
        if inside:
            zone["destination"], zone["destination_yaw"] = inside[0][0], inside[0][1]
        elif zone["kind"] == "STAGE":
            zone["destination"], zone["destination_yaw"] = floor_of(box), 0.0


def implied_zones(z):
    """The two zones a labelled map means without saying.

    A track whose stages start at 1 has already drawn its start line -- stage 1 IS the
    start, in this genre and in Shavit -- and a track whose stages start at 2 has
    drawn a start line and called it that. Both are one zone short of what
    [code]DotTimerZoneSet.problems()[/code] will accept, and in opposite directions.
    """
    for track in z.tracks():
        starts = z.of_kind("START", track)
        stages = z.of_kind("STAGE", track)
        if not stages:
            continue
        first = min(int(s.get("number", 0)) for s in stages)
        if first == 1 and not starts:
            s1 = [s for s in stages if int(s.get("number", 0)) == 1][0]
            z.add("START", track, box=(s1["original_min"], s1["original_max"]),
                  comment="stage 1 is the start line")
        elif first > 1 and starts:
            box = (starts[0]["original_min"], starts[0]["original_max"])
            z.add("STAGE", track, box=box, number=1,
                  destination=starts[0].get("destination"),
                  yaw=starts[0].get("destination_yaw", 0.0),
                  comment="the start line is stage 1")


def spawn_zones(z, spawns, doc):
    """One SPAWN per track: where `spawn_for(track)` puts a player.

    The main track's is NOT simply the biggest cluster of `info_player_*`. On a map
    with a hub -- surf_arcade, surf_beginner2 -- that cluster is the hub, which is not
    on the timed route at all, so a player spawned there can walk around for ever
    without ever crossing a start line. What the start zone contains beats what the
    map's team spawns say, every time.
    """
    given = {int(s.get("track", 0)) for s in doc.get("zones", []) if str(s.get("kind", "")).upper() == "SPAWN"}
    for track in z.tracks():
        if track in given:
            continue
        starts = z.of_kind("START", track)
        at, yaw = None, 0.0
        if starts:
            box = (starts[0].get("original_min", starts[0]["min"]),
                   starts[0].get("original_max", starts[0]["max"]))
            if "destination" in starts[0]:
                at, yaw = starts[0]["destination"], starts[0].get("destination_yaw", 0.0)
            else:
                inside = [s for s in spawns if box_contains(box, s["origin_src"], 32.0)]
                if inside:
                    at, yaw = inside[0]["origin_src"], inside[0]["yaw_src"]
                else:
                    at, yaw = floor_of(box), 0.0
        elif track == 0 and spawns:
            best = pick_spawn(spawns)
            at, yaw = best["origin_src"], best["yaw_src"]
        if at is not None:
            z.add("SPAWN", track, destination=at, yaw=yaw,
                  comment="the spawn for %s" % z.track_names.get(str(track), "track %d" % track))


def drop_unrunnable_tracks(z):
    """A track with a start and no end cannot be run, so it is not offered as one.

    surf_summit's third bonus is the case: a start zone, eight checkpoints and no
    finish anywhere in the map. Left in, it is a track a player can begin and never
    complete, and one [code]DotTimerZoneSet.problems()[/code] refuses the whole map
    over. Dropped silently it would be a bonus that quietly does not exist, so it is
    reported.
    """
    dropped = []
    for track in z.tracks():
        if track == 0:
            continue
        if z.of_kind("START", track) and not z.of_kind("END", track):
            dropped.append((track, z.track_names.get(str(track), str(track))))
        elif z.of_kind("END", track) and not z.of_kind("START", track):
            dropped.append((track, z.track_names.get(str(track), str(track))))
    gone = {t for t, _ in dropped}
    z.zones = [zone for zone in z.zones if zone["track"] not in gone]
    return dropped


def doorway_teleports(z, rule):
    """Teleports a player walks through, as TELEPORT rather than as RESPAWN.

    [b]The difference decides whether a staged map can be played at all.[/b] Every
    `trigger_teleport` in surf_kitsune targets one of nine colours: the flat ones the
    size of a room are the pit under that colour's section, and the ones the size of a
    door are how you leave one section for the next. Treated alike -- which is what
    "every teleport is a RESPAWN" does -- walking out of the first section ends the run
    and puts the player back at the start, for ever.

    The rule is a measurement, opted into per map, because it is only true of a map
    whose sections are joined by doors: nothing here is a door and 512 units wide.
    """
    limit = float(rule.get("max_horizontal", 512.0))
    made = 0
    for i, e in list(z.entities("trigger_teleport")):
        box = brush_box(z.bsp, e)
        if box is None:
            continue
        if max(box[1][0] - box[0][0], box[1][1] - box[0][1]) > limit:
            continue
        hits = z.destinations(e.get("target", ""))
        if not hits:
            continue
        z.claimed.add(i)
        at, yaw = hits[0]
        z.add("TELEPORT", 0, box=box, destination=at, yaw=yaw,
              comment="through to %s" % e.get("target", ""))
        made += 1
    return made


def classify_zones(bsp, min_thickness=MIN_ZONE_THICKNESS, doc=None):
    """Spawns, and every volume a timer cares about.

    Three passes, in the order of how much they know: what the map labelled, what a
    person worked out and wrote in `maps/zones/<id>.json`, and what is left over --
    which is the pit, and always was.
    """
    doc = doc or {}
    z = Zoner(bsp, min_thickness)

    spawns = []
    for e in bsp.entities:
        cls = e.get("classname", "")
        if cls in ("info_player_terrorist", "info_player_counterterrorist",
                   "info_player_start") and "origin" in e:
            src = entity_origin(e)
            # `yaw` is stored converted, like every position beside it: the manifest
            # is Godot axes throughout, and a field that were half-converted is the
            # kind nobody notices until a player spawns facing a wall.
            spawns.append({"origin_src": src, "origin": list(to_godot(src)),
                           "yaw": yaw_to_godot(entity_yaw(e)), "yaw_src": entity_yaw(e)})

    label_zones(z)
    resolve_overrides(z, doc)
    if "doorways" in doc:
        doorway_teleports(z, doc["doorways"])
    implied_zones(z)
    stage_destinations(z)
    spawn_zones(z, spawns, doc)
    dropped = drop_unrunnable_tracks(z)

    push, other = [], []
    for i, e in z.entities("trigger_push", "trigger_multiple", "trigger_once"):
        box = brush_box(bsp, e)
        if box is None:
            continue
        if e.get("classname") == "trigger_push":
            push.append({"min": list(to_godot(box[0])), "max": list(to_godot(box[1]))})
        else:
            other.append({"min": list(to_godot(box[0])), "max": list(to_godot(box[1])),
                          "targetname": e.get("targetname", ""),
                          "filtername": e.get("filtername", "")})

    # What is left of the teleports is the pit: the volume that catches a player who
    # fell off the ride, which is what RESPAWN is and always was the reliable half.
    respawn = []
    for i, e in z.entities("trigger_teleport"):
        box = brush_box(bsp, e)
        if box is None:
            continue
        z.claimed.add(i)
        zone = z.add("RESPAWN", 0, box=box)
        respawn.append({"min": zone["min"], "max": zone["max"],
                        "inflated": zone["inflated"],
                        "original_min": zone["original_min"],
                        "original_max": zone["original_max"]})

    return z, spawns, respawn, push, other, dropped


def emit_zones(z):
    """The zone list as the manifest carries it: genre units, Godot axes."""
    out = []
    for zone in z.zones:
        one = {"kind": zone["kind"], "track": zone["track"]}
        if "number" in zone:
            one["number"] = zone["number"]
        if "min" in zone:
            a, b = to_godot(zone["min"]), to_godot(zone["max"])
            one["min"] = [min(a[i], b[i]) for i in range(3)]
            one["max"] = [max(a[i], b[i]) for i in range(3)]
            one["inflated"] = zone["inflated"]
        if "destination" in zone and zone["destination"] is not None:
            at = to_godot(zone["destination"])
            one["destination"] = [at[0], at[1] + DESTINATION_LIFT, at[2]]
            one["destination_yaw"] = yaw_to_godot(zone.get("destination_yaw", 0.0))
        if zone.get("comment"):
            one["comment"] = zone["comment"]
        out.append(one)
    return out


def pick_spawn(spawns):
    """The spawn a map should start you at.

    A CS:S map has up to 144 of them in two team blocks. The lowest-numbered
    is arbitrary; the CENTRE of the biggest cluster is where the mapper put the start
    pad, and taking the mean over all of them is wrong the moment a map spawns two
    teams at opposite ends.
    """
    if not spawns:
        return {"origin": [0.0, 64.0, 0.0], "origin_src": [0.0, 0.0, 64.0],
                "yaw": yaw_to_godot(0.0), "yaw_src": 0.0}
    best, bestn = spawns[0], 0
    for s in spawns:
        n = sum(1 for o in spawns
                if sum((o["origin"][i] - s["origin"][i]) ** 2 for i in range(3)) < 512 ** 2)
        if n > bestn:
            best, bestn = s, n
    return best


# ------------------------------------------------------------------- driver ---
def load_overrides(path, map_id):
    """What a person worked out about a map, from `maps/zones/<id>.json`.

    [b]Kept beside the repository and not beside the import, because the import is
    output.[/b] `tools/import_maps.sh --force` rewrites every manifest; a hand-written
    zone that lived in one would survive exactly until somebody re-imported the map it
    describes, and would then be gone with nothing saying so.
    """
    if not path:
        return {}
    doc_path = os.path.join(path, map_id + ".json")
    if not os.path.exists(doc_path):
        return {}
    with open(doc_path) as fh:
        return json.load(fh)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("bsp")
    ap.add_argument("out_dir")
    ap.add_argument("--id", default=None, help="map id (default: the file stem)")
    ap.add_argument("--tier", type=int, default=3)
    ap.add_argument("--zones-dir", default=None, dest="zones_dir",
                    help="where per-map zone overrides live "
                         "(default <repo>/maps/zones; see load_overrides)")
    ap.add_argument("--min-zone-thickness", type=float, default=MIN_ZONE_THICKNESS,
                    dest="min_zone_thickness",
                    help="least a zone volume may measure on any axis, in genre units "
                         "(default %d; see MIN_ZONE_THICKNESS)" % MIN_ZONE_THICKNESS)
    a = ap.parse_args(argv)

    map_id = (a.id or os.path.splitext(os.path.basename(a.bsp))[0]).lower()
    d = os.path.join(a.out_dir, map_id)
    os.makedirs(d, exist_ok=True)

    zones_dir = a.zones_dir
    if zones_dir is None:
        zones_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "maps", "zones")
    doc = load_overrides(zones_dir, map_id)

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

    z, spawns, respawn, push, other, dropped = classify_zones(
        bsp, a.min_zone_thickness, doc)
    zones = emit_zones(z)
    for s in spawns:
        s.pop("origin_src", None)
        s.pop("yaw_src", None)

    lo, hi = bsp.model_bounds(0)
    manifest = {
        "id": map_id,
        "source": os.path.basename(a.bsp),
        "units": "genre units (Source units), Godot axes; x metres = x * 0.01905",
        "tier": int(doc.get("tier", a.tier)),
        "bounds": {"min": list(to_godot(lo)), "max": list(to_godot(hi))},
        "lightmap": {"file": os.path.basename(lm_path), "width": lm_w, "height": lm_h},
        "surfaces": surfaces,
        "spawn": pick_spawn(spawns),
        "spawns": spawns,
        "min_zone_thickness": a.min_zone_thickness,
        "zones": zones,
        "track_names": z.track_names,
        "respawn_volumes": respawn,
        "push_volumes": push,
        "trigger_volumes": other,
    }
    for key in ("display_name", "author", "kind", "notes"):
        if key in doc:
            manifest[key] = doc[key]
    # The main track's spawn is what the game puts a player at, and it is not the
    # `spawn` field once a map has a start zone somewhere else -- see spawn_zones.
    main_spawn = [x for x in zones if x["kind"] == "SPAWN" and x["track"] == 0]
    if main_spawn:
        manifest["spawn"] = {"origin": main_spawn[0]["destination"],
                             "yaw": main_spawn[0]["destination_yaw"]}
    with open(os.path.join(d, map_id + ".json"), "w") as fh:
        json.dump(manifest, fh, indent=1)

    tris = sum(s["index_count"] for s in surfaces) // 3
    textured = sum(s["index_count"] for s in surfaces if s["texture"]) // 3
    print("%s -> %s" % (os.path.basename(a.bsp), d))
    print("  %d surfaces, %d tris (%d%% textured from the pakfile)"
          % (len(surfaces), tris, textured * 100 // max(1, tris)))
    print("  lightmap %dx%d, %d lit faces" % (lm_w, lm_h, len(place)))
    inflated = sum(1 for v in respawn if v.get("inflated"))
    print("  %d spawns, %d respawn volumes (%d thickened to %g units), %d push, %d other"
          % (len(spawns), len(respawn), inflated, a.min_zone_thickness, len(push), len(other)))
    for track in sorted({x["track"] for x in zones}):
        kinds = [x["kind"] for x in zones if x["track"] == track]
        stages = max([int(x.get("number", 0)) for x in zones
                      if x["track"] == track and x["kind"] == "STAGE"] or [0])
        print("  track %d (%-6s) %s%s%s, %d stages%s"
              % (track, z.track_names.get(str(track), "?"),
                 "start " if "START" in kinds else "NO START ",
                 "end" if "END" in kinds else "NO END",
                 "" if "SPAWN" in kinds else ", NO SPAWN", stages,
                 ", %d teleports" % kinds.count("TELEPORT") if "TELEPORT" in kinds else ""))
    for track, name in dropped:
        print("  track %d (%s) was dropped: a track needs both a start and an end"
              % (track, name))
    # Said out loud rather than kept: a note nothing prints is this family's own
    # "produced correctly and consumed by nothing", and two volumes quietly becoming
    # one is exactly the kind of thing somebody wants to be told about.
    for note in z.notes:
        print("  note: %s" % note)
    print("  start spawn at %s units" % [round(v) for v in manifest["spawn"]["origin"]])

    print("  drop that directory anywhere the game looks and it is a map:")
    print("    res://maps/imported/, user://maps/, or g2g_maps_directory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
