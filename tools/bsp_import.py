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
                      LUMP_ENTITIES, MASK_PLAYERSOLID, CONTENTS_PLAYERCLIP,
                      SOLID_BRUSH_ENTITIES, NONSOLID_BRUSH_ENTITIES)
import vtf  # noqa: E402

LUMP_LIGHTING, LUMP_PAKFILE, LUMP_PLANES = 8, 40, 1
ATLAS_W = 1024

# Where a map's MEDIAN luxel lands, as a linear value. See build_lightmap.
#
# [b]Anchored on the median rather than on a high quantile, and that is the robust half
# of the exposure.[/b] Setting the white point to the 99th percentile is the obvious
# reading of "use the range", and it hands the exposure of the whole map to whatever its
# brightest few luxels are: `surf_mesa` has a sky and a sane spread and exposed fine,
# `surf_beginner2` has a handful of very bright sources over an otherwise dim map and
# rendered almost black, because its p99 was an outlier rather than its top end. The
# median is a statistic an outlier cannot move.
#
# 0.023 is a code value of about 47 in the sRGB atlas, which is where surf_mesa's median
# sat when it was exposed to its own p99 and rendered against a reference frame. It is a
# level, not a curve: the scale below is linear, so every ratio in the map is the same
# whatever this number is, and changing it moves the whole map up or down together.
EXPOSURE_MEDIAN_TARGET = 0.023
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

# Where the g2gfast roles come from: the angle of the surface, not the name on it.
#
# [b]The material name was a guess and the slope is a fact.[/b] This used to be a list
# of regexes over texture names -- `concretefloor039a` is a ramp, `nodraw` is a
# platform -- on the reasoning that the name is the only intent a compiled .bsp still
# carries. It is not. The geometry carries the one piece of intent that matters here,
# because in this genre what a surface is FOR is exactly what its angle lets a player
# do with it, and that is a number in the plane lump. Measured over the maps in
# `inspirations/`, face area by normal Z comes out in three clean bands every time:
# ~30-43% at +1.0 (floors), ~46-55% at 0.0 (walls) and a distinct 1.6-8.5% at +0.6/+0.7
# -- the ride. The regexes scored none of that: surf_beginner2 came out 97% FLOOR, one
# flat grey mass with the ramps in it invisible.
#
# The threshold is the game's own. A player stands on a surface up to
# `G2GConfig.max_slope` and slides off anything steeper, so that angle is precisely the
# line between "a platform" and "a ramp" -- and painting it anywhere else would be a
# texture that lies about what the movement will do. The default below is that cvar's
# default; `--max-slope` is there for an operator who has changed it.
MAX_SLOPE_DEGREES = 45.57

# Below this the surface is a wall, not a ride. A plane at 87 degrees is vertical for
# every purpose a player has, and calling it a ramp paints slivers of ride colour down
# every wall in the map that was not drawn exactly on the grid.
RAMP_MIN_NORMAL_Z = 0.05


def role_for_normal(nz, cos_limit):
    """What a surface is for, from which way it faces. Source axes: +Z is up."""
    if nz >= cos_limit:
        return "PLATFORM"       # a player stands here
    if nz > RAMP_MIN_NORMAL_Z:
        return "RAMP"           # a player slides off here: the ride
    return "FLOOR"              # walls, ceilings and undersides


# How many of the genre's units one grid square covers. [G2GTextures]'s own
# UNITS_PER_SQUARE, and it has to stay that way: a square is 64 units on every surface
# in this game, in a hand-built map and an imported one alike, because its size in the
# world is the only cue a player has for how fast the ground is moving past them.
#
# [b]A prototype UV here is measured in SQUARES, not in tiles.[/b] How many squares are
# in one tile is a property of the image -- the vendored Kenney tile has eight and the
# generated fallback has four -- and it is not known here, because which of the two a
# map ends up drawn in is decided at load time by what is installed. So the mesh
# carries the part that is about the world and the material scales it by the part that
# is about the texture. Baking a tile count in instead would be a map that silently
# halves its grid the day the texture set is swapped.
UNITS_PER_SQUARE = 64.0


def tangent_frame(n):
    """Two unit axes in the plane of a face, for projecting a prototype grid onto it.

    [b]Not an axis-aligned projection, which is the obvious alternative.[/b] Dropping
    the dominant axis and using the other two is one line, and on a 45-degree surf ramp
    it stretches the grid by a factor of root two along the exact direction the player
    is travelling -- so the one surface whose texture is being read for speed is the one
    surface whose texture is the wrong size. A frame built in the plane has no stretch
    anywhere, and it falls out of it that one axis runs straight down the slope, which
    is the line a surfer steers by.
    """
    up = (0.0, 0.0, 1.0) if abs(n[2]) < 0.9 else (0.0, 1.0, 0.0)
    t = (up[1] * n[2] - up[2] * n[1], up[2] * n[0] - up[0] * n[2],
         up[0] * n[1] - up[1] * n[0])
    ln = math.sqrt(t[0] ** 2 + t[1] ** 2 + t[2] ** 2) or 1.0
    t = (t[0] / ln, t[1] / ln, t[2] / ln)
    b = (n[1] * t[2] - n[2] * t[1], n[2] * t[0] - n[0] * t[2], n[0] * t[1] - n[1] * t[0])
    return t, b


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
    lives in the source game's own archives -- `concrete/concretefloor039a` is stock -- is
    not an error and not a guess: it comes back None and the map script paints it with
    the prototype set instead, keyed by what the surface is FOR.

    [b]A texture that is flat black comes back None too.[/b] It decodes, it is the
    right size, and it is 1024x1024 pixels of nothing -- `tools/toolsblack` and
    `cs_italy/black` between them cover 5.9 billion square units of the eight maps.
    Drawn faithfully that is a hole in the map as far as anybody playing can tell, and
    the whole reason the prototype set exists is to stand in for a surface there is no
    picture of. Having one and having a black one are the same situation. See
    [method vtf.is_blank] for why the rule is flat-and-dark rather than just dark.
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
            # None here is a texture already found to be blank, not one never seen:
            # `written` is keyed by base texture and a second material pointing at the
            # same blank one has to reach the same answer, translucency included.
            out[mat] = (written[base], translucent if written[base] else False)
            continue
        name = base.replace("/", "_") + ".png"
        try:
            w, h, px = vtf.decode(raw)
        except ValueError:
            out[mat] = (None, translucent)      # HDR cubemaps and other oddities
            continue
        if vtf.is_blank(px):
            out[mat] = (None, False)
            written[base] = None
            continue
        opaque = not translucent and vtf.is_opaque(px)
        vtf.write_png(os.path.join(tex_dir, name), w, h, px, opaque=opaque)
        written[base] = name
        out[mat] = (name, translucent and not opaque)
    return out


# --------------------------------------------------------------- lightmap ----
def lightmap_quantile(light, lit, q, stride=7):
    """The q-th quantile of a map's lit luxel luminances, in Source's linear units.

    Sampled rather than counted in full -- a big map has two million luxels and every
    one of them costs a Python loop -- and every seventh is plenty for a quantile that
    only has to be right to within a stop. Falls back to 1.0 for a map with no lighting
    at all, which makes the exposure below a no-op rather than a divide by zero.
    """
    vals = []
    for f in lit:
        o, w, h = f[9], f[13] + 1, f[14] + 1
        end = o + w * h * 4
        for t in range(o, min(end, len(light) - 3), 4 * stride):
            e = light[t + 3]
            scale = 2.0 ** (e - 256 if e > 127 else e)
            vals.append((light[t] * 0.2126 + light[t + 1] * 0.7152
                         + light[t + 2] * 0.0722) * scale)
    if not vals:
        return 1.0
    vals.sort()
    return max(vals[min(int(q * (len(vals) - 1)), len(vals) - 1)], 1e-6)


def build_lightmap(bsp, faces, path):
    """Pack every lit face's luxels into one atlas and return its placements.

    Source stores lighting as RGBE -- three bytes and a shared signed exponent -- so a
    luxel can be far brighter than white, which is the point: it is light, not a
    colour. It is tone-mapped down here rather than in the shader so the atlas is an
    ordinary sRGB PNG that Godot imports with no special handling.

    [b]Exposed and gamma-encoded, and NOT tone-mapped. A tone map here is the bug.[/b]
    Two encodings stood here before this one and both were wrong in the same place.
    `v = min(1, c * 2**e / 255)` divided by the range of the MANTISSA byte rather than
    by anything the number means, and put the median luxel at 0.03. Reinhard,
    `v / (v + key)` against the map's own median, replaced it and fixed the darkness --
    but Reinhard is a DISPLAY operator and this is not a display, it is a light term
    that still has to be multiplied by an albedo. It compresses ratios everywhere,
    including the midtones where every readable thing in a map lives.

    That was measured against a reference frame of one of these maps as its own engine
    draws it. The reference spans a linear luminance ratio of 303:1 from its darkest
    fifth-percentile pixel to its brightest ninety-fifth; the same view of our import
    spanned 7.9:1. A cave lit by one warm lamp came out as an evenly grey room. Nothing
    about the geometry, the textures or the albedo was wrong -- the light had simply had
    its contrast removed before it ever reached the shader.

    So: expose, clip, encode. Linear light is divided by the map's own
    [code]EXPOSURE_QUANTILE[/code] luxel so that the bright end lands at white, anything
    above that clips -- which the source engine also does, since its overbright range is
    finite too -- and the result is written through gamma 2.2. **Every ratio below the
    clip survives exactly**, which is the entire point: gamma encoding is already the
    compression an 8-bit image needs, and a 500:1 linear range is what sRGB was designed
    to carry. The atlas is still an ordinary sRGB PNG that Godot imports with no special
    handling, and `source_color` on the sampler undoes the gamma on the way back to
    linear, so the shader multiplies an honest light value by an honest albedo.

    Each map still exposes itself against its own light, which is what "a map is
    content" has to mean when the content is somebody else's compile.
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

    white = lightmap_quantile(light, lit, 0.5) / EXPOSURE_MEDIAN_TARGET
    inv_gamma = 1.0 / 2.2
    clipped = 0
    total = 0
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
                s = 2.0 ** (e - 256 if e > 127 else e)
                p = (row + px + i) * 4
                for k in range(3):
                    v = light[q + k] * s / white
                    total += 1
                    if v > 1.0:
                        v = 1.0
                        clipped += 1
                    atlas[p + k] = int(255.0 * (v ** inv_gamma))
    vtf.write_png(path, ATLAS_W, height, bytes(atlas), opaque=True)
    # Reported because it is the one number that says whether a map's exposure is sane:
    # a few per cent is light sources doing what light sources do, and a large fraction
    # is a map whose midtones have been pushed off the top of the range.
    return place, ATLAS_W, height, (100.0 * clipped / total if total else 0.0)


# ----------------------------------------------------------------- meshing ----
def face_normal(bsp, f):
    """A face's outward normal: its own plane's, and not conditionally flipped.

    [b]This used to negate when `dface_t.side` was set, and that is wrong here.[/b]
    `side` records which side of the NODE's plane the face fell on, which is a fact
    about the tree; the face's own `planenum` already points at the right one of the
    plane pair, because a Source BSP stores every plane twice with opposite normals and
    vbsp writes the twin. Negating on top of that inverted the normal of every face
    with the flag -- 26% of surf_year3000, 40% of surf_beginner2.

    Measured rather than reasoned about, because the documentation for that field reads
    both ways. For 1500 faces of surf_year3000 the centroid was pushed six units each
    way and tested against every solid brush in the map: where one side was solid and
    the other was not -- 908 of them -- the plane normal pointed away from the solid
    908 times with the side flag clear and 178 times with it set, and pointed into the
    solid twice in total.

    [b]Nothing could see it until now.[/b] The normals went into ARRAY_NORMAL and the
    shader that reads them is `unshaded`, so a map lit by its own baked lightmap looks
    identical either way, and backface culling follows the winding rather than the
    normal. It is visible for the first time because the surface roles are read off the
    slope now, and an inverted normal makes a ceiling a platform.
    """
    return bsp.planes[f[0]][:3]


def build_mesh(bsp, lm_place, lm_w, lm_h, textured, cos_limit, prototype):
    """One vertex block and one index block per (material, role).

    [b]Per role and not per material, because a role is per face.[/b] The role comes
    from the slope now (see `role_for_normal`), and one material is used at every angle
    a map has -- `concretefloor039a` is the ride surface AND the walls of the corridor
    around it. Keyed by material alone, the whole map takes whichever role its first
    face happened to have, which is how surf_beginner2 came out 97% FLOOR.

    `textured` says which materials the pakfile actually carried. A material it did not
    -- stock, which is most of what a surf map is built from -- gets the prototype
    set instead of the flat role colour it used to get, and needs a different UV to do
    it: the map's own UVs place a texture the way the mapper placed it, and a prototype
    grid has to be placed in the world instead, at one size everywhere. So the two UVs
    cannot both be written and the choice is made here, per surface.
    """
    groups = collections.defaultdict(lambda: ([], []))     # (mat, role) -> (verts, indices)
    dedupe = collections.defaultdict(dict)

    def emit(key, pos_src, nrm_src, uv, uv2):
        verts, _ = groups[key]
        k = (round(pos_src[0], 2), round(pos_src[1], 2), round(pos_src[2], 2),
             round(nrm_src[0], 3), round(nrm_src[1], 3), round(nrm_src[2], 3),
             round(uv[0], 4), round(uv[1], 4), round(uv2[0], 5), round(uv2[1], 5))
        d = dedupe[key]
        if k in d:
            return d[k]
        g, gn = to_godot(pos_src), to_godot(nrm_src)
        verts.append((g, gn, uv, uv2))
        d[k] = len(verts) - 1
        return len(verts) - 1

    white = (2.0 / lm_w, 2.0 / lm_h)

    for f in bsp.model_faces(0):
        mat_raw, flags = bsp.face_material(f)
        if flags & SKIP_MASK:
            continue
        mat = clean_material(mat_raw)
        n = face_normal(bsp, f)
        role = role_for_normal(n[2], cos_limit)
        # `all` repaints the map's own textures too; `auto` keeps them and only fills
        # in the ones that lived in the game's VPKs and were never in this file.
        use_prototype = prototype == "all" or (prototype == "auto" and mat not in textured)
        key = (mat, role, use_prototype)

        ti = bsp.texinfo[f[5]]
        tw, th = 1, 1
        td = int(ti[17])
        if 0 <= td < len(bsp.texdata):
            tw, th = max(1, bsp.texdata[td][4]), max(1, bsp.texdata[td][5])
        tan, bit = tangent_frame(n)

        def uv_of(p):
            if use_prototype:
                return ((p[0] * tan[0] + p[1] * tan[1] + p[2] * tan[2]) / UNITS_PER_SQUARE,
                        (p[0] * bit[0] + p[1] * bit[1] + p[2] * bit[2]) / UNITS_PER_SQUARE)
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

        _, idx = groups[key]
        if f[6] >= 0:
            # Each point comes back as (displaced, flat). The flat one is only used for
            # the lightmap coordinate -- see `displacement_tris` for why a displacement's
            # lighting is parameterised over the quad rather than over the terrain.
            tris = bsp.displacement_tris(f, with_base=True)
            # Displacements are terrain: average the normals over the grid so a
            # rock face is not a field of flat triangles. Brush faces below keep
            # their exact plane normal, because a surf ramp's edge IS sharp.
            acc = collections.defaultdict(lambda: [0.0, 0.0, 0.0])
            for t in tris:
                u = [t[1][0][i] - t[0][0][i] for i in range(3)]
                v = [t[2][0][i] - t[0][0][i] for i in range(3)]
                nn = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2],
                      u[0] * v[1] - u[1] * v[0]]
                for p, _flat in t:
                    k = (round(p[0], 2), round(p[1], 2), round(p[2], 2))
                    for i in range(3):
                        acc[k][i] += nn[i]
            for t in tris:
                for p, flat in t:
                    k = (round(p[0], 2), round(p[1], 2), round(p[2], 2))
                    nn = acc[k]
                    ln = math.sqrt(sum(c * c for c in nn)) or 1.0
                    idx.append(emit(key, p, [c / ln for c in nn], uv_of(p), uv2_of(flat)))
        else:
            pts = bsp.face_points(f)
            if len(pts) < 3:
                continue
            ring = [emit(key, p, n, uv_of(p), uv2_of(p)) for p in pts]
            for k in range(1, len(ring) - 1):
                # Source winds its faces the other way round from Godot's front face.
                idx.extend((ring[0], ring[k + 1], ring[k]))

    surfaces, blob = [], bytearray()
    for key in sorted(groups):
        mat, role, use_prototype = key
        verts, idx = groups[key]
        if not idx:
            continue
        voff = len(blob)
        for g, gn, uv, uv2 in verts:
            blob += struct.pack("<10f", g[0], g[1], g[2], gn[0], gn[1], gn[2],
                                uv[0], uv[1], uv2[0], uv2[1])
        ioff = len(blob)
        for i in idx:
            blob += struct.pack("<I", i)
        surfaces.append({"material": mat, "role": role, "prototype": use_prototype,
                         "vertex_offset": voff, "vertex_count": len(verts),
                         "index_offset": ioff, "index_count": len(idx)})
    return surfaces, bytes(blob)


# ---------------------------------------------------------------- collision ---
def build_collision(bsp, notes):
    """Every solid in the map as convex hulls, plus the displacements as triangles.

    [b]This is the half the importer did not have, and the one a player notices.[/b]
    Collision used to be `create_trimesh_collision()` over the drawn mesh, and the
    drawn mesh is not the solid: see MASK_PLAYERSOLID in bsp_read. A `nodraw` face is
    absent from it, a `toolsplayerclip` brush is absent from it entirely, and on
    Surf_Mesa 77% of the sides of a solid brush are one or the other -- so the
    collision shell had holes in it the size of the brushes it was meant to be, and a
    player fell through the map.

    [b]Convex per brush, and not one big trimesh, because this is a surf game.[/b] A
    concave shape collides as loose triangles, and a hull sliding across one meets
    every interior edge between them -- the classic catch on a seam in a flat floor,
    which on a 45-degree ramp at 3000 u/s is a run ended by a bump that is not there.
    A brush is convex by construction and Godot's solver treats a convex shape as one
    surface with no interior edges at all, which is exactly the guarantee Source's own
    player movement is built on. It is also what makes the count affordable: 2500
    boxes and wedges is cheap to broadphase, and it is the shape the mapper drew.

    Displacements are the exception and get triangles, because a displacement is
    terrain and is not convex in any useful way. There are 1850 of them in surf_summit
    and 1434 in Surf_Mesa, several of which are ramps players ride.
    """
    hulls = []

    def add_model(model, offset, why):
        for i in sorted(bsp.model_brushes(model)):
            contents = bsp.brushes[i][2]
            if not contents & MASK_PLAYERSOLID:
                continue
            pts = bsp.brush_hull(i)
            if len(pts) < 4:
                # A brush whose sides do not enclose anything. Not fatal and not
                # silent: it is either a reader bug or a brush the compiler broke,
                # and both are things a person wants to be told.
                notes.append("%s brush %d has no hull (%d corners)" % (why, i, len(pts)))
                continue
            hulls.append((pts, offset, contents))

    add_model(0, (0.0, 0.0, 0.0), "world")

    skipped = collections.Counter()
    for e in bsp.entities:
        model = e.get("model", "")
        if not model.startswith("*"):
            continue
        index = int(model[1:])
        if not 0 < index < len(bsp.models):
            continue
        name = e.get("classname", "?")
        if name in SOLID_BRUSH_ENTITIES:
            add_model(index, tuple(entity_origin(e)), name)
        else:
            skipped[name] += 1
            if name not in NONSOLID_BRUSH_ENTITIES and not name.startswith("trigger_"):
                notes.append("%s is a brush entity neither list in bsp_read knows; "
                             "treated as non-solid" % name)

    # No count in front of the hulls: the manifest already carries `hull_count`, and a
    # second copy of a number is a second thing that can be wrong. The block is a bare
    # run of <point count><points>, the way the surface blocks above are bare arrays.
    blob = bytearray()
    clips = 0
    for pts, off, contents in hulls:
        if contents & CONTENTS_PLAYERCLIP:
            clips += 1
        blob += struct.pack("<I", len(pts))
        for p in pts:
            blob += struct.pack("<3f", *to_godot([p[a] + off[a] for a in range(3)]))

    # The displacement surface, welded across the whole map so that two displacements
    # sharing an edge share its vertices -- an unwelded seam is a crack a hull can
    # catch on, which is the one thing the convex half above exists to avoid.
    verts, index_of, tris = [], {}, []
    for f in bsp.faces:
        if f[6] < 0:
            continue
        if bsp.face_material(f)[1] & SKIP_MASK:
            continue
        for t in bsp.displacement_tris(f):
            for point in t:
                key = (round(point[0], 2), round(point[1], 2), round(point[2], 2))
                i = index_of.get(key)
                if i is None:
                    i = index_of[key] = len(verts)
                    verts.append(to_godot(point))
                tris.append(i)

    vertex_offset = len(blob)
    for v in verts:
        blob += struct.pack("<3f", *v)
    index_offset = len(blob)
    for i in tris:
        blob += struct.pack("<I", i)

    info = {
        "hull_count": len(hulls),
        "hull_offset": 0,
        "displacement_vertex_offset": vertex_offset,
        "displacement_vertex_count": len(verts),
        "displacement_index_offset": index_offset,
        "displacement_index_count": len(tris),
        "playerclip_hulls": clips,
    }
    return bytes(blob), info, skipped


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
    away.[/b] The comment that stood here said a surf map of this genre has no convention for
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
# the floor's height is the state dot-player-controller's own notes describe as never
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
    """The middle of a box's floor. Where a `!s3` puts a player.

    [b]A trigger's floor is not the map's floor, and this is where a player is left
    standing inside one.[/b] `box[0][2]` is the bottom of the VOLUME, and a mapper sinks
    a trigger into the ground on purpose so nobody can walk under its lower edge — so on
    every map whose start zone has no `info_player_*` inside it, the spawn came out
    somewhere below the surface. Measured afterwards with `tools/spawn_check.gd`:
    surf_aquaflow's main spawn was **64 units** inside solid, against a 72-unit player.

    The box is still the right answer for WHERE; [method lift_out_of_solid] is what makes
    it an answer for HOW HIGH, and it has the brush data to know.
    """
    return [(box[0][0] + box[1][0]) * 0.5, (box[0][1] + box[1][1]) * 0.5, box[0][2]]


def point_in_brush(bsp, index, point, epsilon=0.1):
    """Is a point inside one brush? True when it is behind every one of its sides.

    A Source brush is the intersection of its half-spaces, so this is the definition
    rather than an approximation of it.
    """
    first, count, _ = bsp.brushes[index]
    for side in bsp.brushsides[first:first + count]:
        pl = bsp.planes[side[0]]
        if pl[0] * point[0] + pl[1] * point[1] + pl[2] * point[2] - pl[3] > epsilon:
            return False
    return True


def lift_out_of_solid(bsp, point, height=72.0, limit=256.0):
    """Raise a spawn point until a player standing on it is not inside a brush.

    Source is Z-up here -- this runs before the axis swap -- so "up" is +Z.

    [b]Checked at the FEET and at the head, because a spawn can be wrong either way.[/b]
    A point on a trigger's floor is usually a few units into the ground; a point under a
    low ceiling is clear at the feet and not at the head, and a player spawned there is
    stuck just as thoroughly.

    Gives up at [param limit] and returns the point unchanged rather than teleporting
    somebody an arbitrary distance: a spawn that is a quarter of the map deep in solid is
    a map this importer has read wrongly somewhere else, and moving it would hide that.

    [b]IT CANNOT SEE DISPLACEMENTS, AND THAT IS THE CASE IT WAS WRITTEN FOR.[/b] Brushes
    are half-spaces and a point test against them is exact; a displacement is terrain,
    welded triangles with no inside, and there is no cheap containment test for one here.
    `surf_aquaflow`'s main spawn — the one that prompted this, 64 units under the surface
    against a 72-unit player — is buried in the reef, which is displacement, so this
    function looks at it and correctly reports it clear. It fixes a spawn inside a BRUSH
    and nothing else, and `tools/spawn_check.gd` still finds 36 bad points across five
    maps after it runs.
    
    The answer is almost certainly not here: the game has a physics world and one shape
    query per spawn at map load would settle brushes and terrain alike, in the one place
    that knows about both. Left in because a brush-buried spawn is still a real case and
    the next person needs to know which half is covered.
    """
    solid = [i for i in range(len(bsp.brushes))
             if bsp.brushes[i][2] & MASK_PLAYERSOLID]

    def blocked(at):
        for probe in (at, [at[0], at[1], at[2] + height * 0.5],
                      [at[0], at[1], at[2] + height - 1.0]):
            for i in solid:
                if point_in_brush(bsp, i, probe):
                    return True
        return False

    if not blocked(point):
        return point

    step = 4.0
    raised = 0.0
    while raised < limit:
        raised += step
        lifted = [point[0], point[1], point[2] + raised]
        if not blocked(lifted):
            return lifted
        step *= 1.5
    return point


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


def spawn_zones(z, spawns, doc, bsp=None):
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
            # [b]Every route to `at` above can land inside a brush, and only one of them
            # is obviously wrong.[/b] `floor_of` takes a trigger's own underside, which
            # is below the ground by design; a `destination` is wherever the mapper put
            # an entity, which on a teleport aimed at a doorway can be in the door frame;
            # and an `info_player_*` origin is at the feet, so a map that moved its floor
            # after placing one leaves it buried. Checked here rather than per-route,
            # because the failure is the same and a player stuck in a wall does not care
            # which of the three put them there.
            if bsp is not None:
                at = lift_out_of_solid(bsp, at)
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
    spawn_zones(z, spawns, doc, bsp)
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

    One of these maps has up to 144 of them in two team blocks. The lowest-numbered
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
def _numbers(value, count):
    """The first [param count] numbers out of a Source key like `"235 222 177 600"`."""
    parts = str(value).replace(",", " ").split()
    out = []
    for token in parts[:count]:
        try:
            out.append(float(token))
        except ValueError:
            return None
    return out if len(out) == count else None


def lighting_of(bsp):
    """The lighting the map already describes, as a document a renderer can read.

    [b]Every one of these maps says how it is lit and nothing has ever read it.[/b] The
    geometry, the zones, the spawns and the baked lightmap all come out of the .bsp, and
    then the sun angle, the sun colour, the ambient colour, the fog and the sky name --
    which the mapper set deliberately and which vrad and the engine both used -- were
    left in the entity lump. So an imported map is drawn under a hardcoded sun at
    (-55, -35) with a flat blue-grey background, on every map, whatever the map says.
    `Surf_Mesa` wants a sun at -28 degrees in warm 235/222/177 with fog from 5000 units;
    `surf_beginner2` wants one straight overhead in 255/211/168. They looked like two
    different games and they were lit like one.

    Everything here is optional: a map with no `light_environment` returns a document
    with no sun in it, and the consumer keeps its own default. That is the same contract
    as every other block in this manifest -- absent means "nothing said", never zero.

    Source's `_light` is four numbers, RGB plus a brightness that is NOT a multiplier on
    a 0-255 colour but the intensity vrad compiled with; it is carried through as it
    stands rather than folded in, because what a renderer should do with 600 is a
    renderer's decision and folding it here would throw the colour away.
    """
    out = {}

    env = next((e for e in bsp.entities if e.get("classname") == "light_environment"), None)
    if env is not None:
        sun = {}
        angles = _numbers(env.get("angles", ""), 3)
        # `pitch` overrides the pitch in `angles` when both are present, which is a
        # Source quirk rather than a choice: the entity has a separate pitch key because
        # angles[0] is clamped in Hammer's UI and mappers need the range.
        pitch = _numbers(env.get("pitch", ""), 1)
        if angles:
            sun["yaw_src"] = angles[1]
            sun["pitch_src"] = pitch[0] if pitch else angles[0]
        elif pitch:
            sun["pitch_src"] = pitch[0]
        light = _numbers(env.get("_light", ""), 4)
        if light:
            sun["colour"] = [c / 255.0 for c in light[:3]]
            sun["brightness"] = light[3]
        ambient = _numbers(env.get("_ambient", ""), 4)
        if ambient:
            sun["ambient_colour"] = [c / 255.0 for c in ambient[:3]]
            sun["ambient_brightness"] = ambient[3]
        spread = _numbers(env.get("SunSpreadAngle", ""), 1)
        if spread:
            sun["spread_degrees"] = spread[0]
        if sun:
            out["sun"] = sun

    fog_ent = next((e for e in bsp.entities
                    if e.get("classname") == "env_fog_controller"), None)
    if fog_ent is not None:
        fog = {}
        for key, name in (("fogstart", "start"), ("fogend", "end"),
                          ("fogmaxdensity", "max_density")):
            value = _numbers(fog_ent.get(key, ""), 1)
            if value:
                fog[name] = value[0]
        colour = _numbers(fog_ent.get("fogcolor", ""), 3)
        if colour:
            fog["colour"] = [c / 255.0 for c in colour]
        # `fogenable` absent means off in Source, so absence is a real answer here and
        # not a missing one.
        fog["enabled"] = str(fog_ent.get("fogenable", "0")).strip() in ("1", "true")
        if len(fog) > 1:
            out["fog"] = fog

    world = next((e for e in bsp.entities if e.get("classname") == "worldspawn"), None)
    if world is not None and world.get("skyname"):
        out["sky_name"] = str(world["skyname"])

    # The count only, not the lights. A point light in Source is an input to vrad and
    # its output is already in the lightmap this importer bakes down -- placing 148 real
    # lights would light the map twice. It is carried because "this map has 148 lights
    # in it and none of them are dynamic" is worth being able to say out loud, and
    # because a renderer that ever wants glow around them needs to know they exist.
    out["baked_light_count"] = sum(
        1 for e in bsp.entities
        if e.get("classname") in ("light", "light_spot")
    )

    return out


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
    ap.add_argument("--prototype", choices=("auto", "all", "off"), default="auto",
                    help="paint surfaces with the prototype texture set: `auto` only "
                         "where the .bsp carried no texture of its own (default), "
                         "`all` everywhere, `off` never")
    ap.add_argument("--max-slope", type=float, default=MAX_SLOPE_DEGREES,
                    dest="max_slope",
                    help="the steepest a player can stand on, in degrees; the line "
                         "between a PLATFORM and a RAMP. Must match G2GConfig.max_slope "
                         "(default %g)" % MAX_SLOPE_DEGREES)
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
    place, lm_w, lm_h, lm_clipped = build_lightmap(bsp, faces, lm_path)

    # The textures are decoded BEFORE the mesh, because which of them the pakfile
    # actually carried is what decides whether a surface gets the map's own UVs or a
    # world-placed prototype grid, and a vertex can only carry one of the two.
    pak = read_pak(bsp)
    materials = sorted({clean_material(bsp.face_material(f)[0]) for f in faces})
    tex = extract_textures(pak, materials, os.path.join(d, "textures"))
    textured = {m for m, (png, _) in tex.items() if png}

    cos_limit = math.cos(math.radians(a.max_slope))
    surfaces, mesh_blob = build_mesh(bsp, place, lm_w, lm_h, textured, cos_limit,
                                     a.prototype)
    for s in surfaces:
        png, translucent = tex.get(s["material"], (None, False))
        s["texture"] = None if s["prototype"] else png
        s["translucent"] = translucent and not s["prototype"]

    notes = []
    collision_blob, collision, skipped_entities = build_collision(bsp, notes)
    # The collision block lives in the same .bin, after the mesh, so a map is still the
    # four files it was. Its offsets are written relative to its own block and shifted
    # here, which keeps build_collision independent of what precedes it.
    for key in ("hull_offset", "displacement_vertex_offset", "displacement_index_offset"):
        collision[key] += len(mesh_blob)
    with open(os.path.join(d, map_id + ".bin"), "wb") as fh:
        fh.write(mesh_blob)
        fh.write(collision_blob)

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
        "lighting": lighting_of(bsp),
        "surfaces": surfaces,
        "collision": collision,
        "units_per_square": UNITS_PER_SQUARE,
        "max_slope": a.max_slope,
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
    from_pak = sum(s["index_count"] for s in surfaces if s["texture"]) // 3
    print("%s -> %s" % (os.path.basename(a.bsp), d))
    print("  %d surfaces, %d tris (%d%% textured from the pakfile, %d%% prototype)"
          % (len(surfaces), tris, from_pak * 100 // max(1, tris),
             (tris - from_pak) * 100 // max(1, tris)))
    by_role = collections.Counter()
    for s in surfaces:
        by_role[s["role"]] += s["index_count"] // 3
    print("  roles at %g degrees: %s" % (a.max_slope, ", ".join(
        "%s %d%%" % (r, by_role[r] * 100 // max(1, tris))
        for r in ("PLATFORM", "RAMP", "FLOOR"))))
    print("  collision: %d convex hulls (%d of them playerclip), %d displacement tris"
          % (collision["hull_count"], collision["playerclip_hulls"],
             collision["displacement_index_count"] // 3))
    if skipped_entities:
        print("  %d brush entities left non-solid: %s"
              % (sum(skipped_entities.values()),
                 ", ".join("%s x%d" % kv for kv in skipped_entities.most_common(6))))
    print("  lightmap %dx%d, %d lit faces, %.1f%% of luxels clipped to white"
          % (lm_w, lm_h, len(place), lm_clipped))
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
    for note in z.notes + notes:
        print("  note: %s" % note)
    print("  start spawn at %s units" % [round(v) for v in manifest["spawn"]["origin"]])

    print("  drop that directory anywhere the game looks and it is a map:")
    print("    res://maps/imported/, user://maps/, or g2g_maps_directory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
