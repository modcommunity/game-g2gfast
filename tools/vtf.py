#!/usr/bin/env python3
"""Decode Valve Texture Format (VTF) images, and write PNGs, with no dependencies.

Written by hand rather than pulled from a package because this tree installs
nothing: the Godot side has no Python dependency at all today, and a converter that
needs `pip install` is one that stops working on the next machine. PNG output is
zlib plus four CRCs; DXT decoding is the S3TC block layout, which has not changed
since 1999.
"""

import struct
import zlib

# VTF high-res image formats. Only the ones map textures actually use are decoded;
# the rest raise rather than silently producing garbage pixels.
RGBA8888, ABGR8888, RGB888, BGR888, RGB565 = 0, 1, 2, 3, 4
I8, IA88, P8, A8 = 5, 6, 7, 8
ARGB8888, BGRA8888 = 11, 12
DXT1, DXT3, DXT5 = 13, 14, 15
BGRX8888, BGR565, DXT1_ONEBITALPHA = 16, 17, 20

_BLOCK = {DXT1: 8, DXT1_ONEBITALPHA: 8, DXT3: 16, DXT5: 16}
_LINEAR = {RGBA8888: 4, ABGR8888: 4, ARGB8888: 4, BGRA8888: 4, BGRX8888: 4,
           RGB888: 3, BGR888: 3, RGB565: 2, BGR565: 2, IA88: 2, I8: 1, A8: 1, P8: 1}


def _image_size(fmt, w, h):
    if fmt in _BLOCK:
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * _BLOCK[fmt]
    if fmt in _LINEAR:
        return w * h * _LINEAR[fmt]
    raise ValueError("unsupported VTF format %d" % fmt)


def _rgb565(c):
    return (((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63, (c & 31) * 255 // 31)


def _decode_dxt(data, fmt, w, h):
    """S3TC to RGBA bytes. Blocks are 4x4 and the image is padded up to them."""
    out = bytearray(w * h * 4)
    bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
    stride = _BLOCK[fmt]
    o = 0
    for by in range(bh):
        for bx in range(bw):
            blk = data[o:o + stride]
            o += stride
            if len(blk) < stride:
                break
            alpha = [255] * 16
            cofs = 0
            if fmt == DXT3:
                cofs = 8
                for i in range(8):
                    v = blk[i]
                    alpha[i * 2] = (v & 15) * 17
                    alpha[i * 2 + 1] = (v >> 4) * 17
            elif fmt == DXT5:
                cofs = 8
                a0, a1 = blk[0], blk[1]
                tbl = [a0, a1]
                if a0 > a1:
                    tbl += [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
                else:
                    tbl += [((5 - i) * a0 + i * a1) // 5 for i in range(1, 5)] + [0, 255]
                bits = int.from_bytes(blk[2:8], "little")
                for i in range(16):
                    alpha[i] = tbl[(bits >> (3 * i)) & 7]
            c0, c1 = struct.unpack_from("<HH", blk, cofs)
            idx = int.from_bytes(blk[cofs + 4:cofs + 8], "little")
            r0, g0, b0 = _rgb565(c0)
            r1, g1, b1 = _rgb565(c1)
            pal = [(r0, g0, b0, 255), (r1, g1, b1, 255)]
            if c0 > c1 or fmt not in (DXT1, DXT1_ONEBITALPHA):
                pal.append(((2 * r0 + r1) // 3, (2 * g0 + g1) // 3, (2 * b0 + b1) // 3, 255))
                pal.append(((r0 + 2 * r1) // 3, (g0 + 2 * g1) // 3, (b0 + 2 * b1) // 3, 255))
            else:
                # 1-bit alpha mode: the fourth entry is transparent black, and using
                # the interpolated colour there is the classic "black fringe" bug.
                pal.append(((r0 + r1) // 2, (g0 + g1) // 2, (b0 + b1) // 2, 255))
                pal.append((0, 0, 0, 0))
            for py in range(4):
                y = by * 4 + py
                if y >= h:
                    break
                for px in range(4):
                    x = bx * 4 + px
                    if x >= w:
                        continue
                    i = py * 4 + px
                    r, g, bl, a = pal[(idx >> (2 * i)) & 3]
                    p = (y * w + x) * 4
                    out[p] = r; out[p + 1] = g; out[p + 2] = bl
                    out[p + 3] = a if fmt in (DXT1, DXT1_ONEBITALPHA) else alpha[i]
    return bytes(out)


def _decode_linear(data, fmt, w, h):
    n = w * h
    out = bytearray(n * 4)
    if fmt in (RGBA8888,):
        return bytes(data[:n * 4])
    for i in range(n):
        p = i * 4
        if fmt == BGRA8888 or fmt == BGRX8888:
            b, g, r, a = data[i * 4:i * 4 + 4]
            if fmt == BGRX8888:
                a = 255
        elif fmt == ABGR8888:
            a, b, g, r = data[i * 4:i * 4 + 4]
        elif fmt == ARGB8888:
            a, r, g, b = data[i * 4:i * 4 + 4]
        elif fmt == RGB888:
            r, g, b = data[i * 3:i * 3 + 3]; a = 255
        elif fmt == BGR888:
            b, g, r = data[i * 3:i * 3 + 3]; a = 255
        elif fmt in (RGB565, BGR565):
            c = struct.unpack_from("<H", data, i * 2)[0]
            r, g, b = _rgb565(c)
            if fmt == BGR565:
                r, b = b, r
            a = 255
        elif fmt == IA88:
            r = g = b = data[i * 2]; a = data[i * 2 + 1]
        elif fmt in (I8, P8):
            r = g = b = data[i]; a = 255
        elif fmt == A8:
            r = g = b = 255; a = data[i]
        else:
            raise ValueError(fmt)
        out[p] = r; out[p + 1] = g; out[p + 2] = b; out[p + 3] = a
    return bytes(out)


def decode(raw):
    """A VTF's largest mip level, as (width, height, RGBA bytes)."""
    if raw[:4] != b"VTF\0":
        raise ValueError("not a VTF")
    vmaj, vmin = struct.unpack_from("<II", raw, 4)
    header_size = struct.unpack_from("<I", raw, 12)[0]
    width, height, flags, frames = struct.unpack_from("<HHIH", raw, 16)
    fmt = struct.unpack_from("<I", raw, 52)[0]
    mips = raw[56]
    low_fmt, low_w, low_h = struct.unpack_from("<IBB", raw, 57)

    off = header_size
    if low_fmt != 0xFFFFFFFF and low_w and low_h:
        off += _image_size(low_fmt, low_w, low_h)

    # Mips are stored smallest first, so the full-size image is last. Walking
    # forward and stopping at mip 0 is the obvious approach and it is wrong --
    # mip 0 is the END of the run, not the start.
    sizes = []
    for m in range(mips - 1, -1, -1):
        sizes.append(_image_size(fmt, max(1, width >> m), max(1, height >> m)))
    pos = off + sum(sizes[:-1]) * max(1, frames)
    data = raw[pos:pos + sizes[-1]]
    if len(data) < sizes[-1]:                      # truncated or an unusual layout
        data = raw[len(raw) - sizes[-1]:]
    if fmt in _BLOCK:
        return width, height, _decode_dxt(data, fmt, width, height)
    return width, height, _decode_linear(data, fmt, width, height)


def write_png(path, w, h, rgba, opaque=False):
    """A PNG, straight from zlib. RGB8 when nothing is transparent, else RGBA8."""
    if opaque:
        rows = bytearray()
        for y in range(h):
            rows.append(0)
            r = rgba[y * w * 4:(y + 1) * w * 4]
            rows += bytes(b for i in range(0, len(r), 4) for b in r[i:i + 3])
        ctype, bpp = 2, 3
    else:
        rows = bytearray()
        for y in range(h):
            rows.append(0)
            rows += rgba[y * w * 4:(y + 1) * w * 4]
        ctype, bpp = 6, 4

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 6))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def is_opaque(rgba):
    return all(rgba[i] == 255 for i in range(3, len(rgba), 4))


def is_blank(rgba, stride=37):
    """A flat dark image: a texture with nothing in it.

    [b]`tools/toolsblack` decodes perfectly and is 1024x1024 pixels of zero.[/b] So do
    `cs_italy/black` and the handful like it, and between them they are 5.9 billion
    square units across the eight maps -- drawn, correctly, as absolutely nothing,
    which to a player is indistinguishable from a texture that failed to load. The
    caller routes these to the prototype set instead, the same way it routes a texture
    that was never in the file, because "no texture" is what both of them are.

    Flat AND dark, not either: a flat white panel is a light and reads as one, and a
    dark texture with something in it is a dark texture. `grids/grid_white` is exactly
    that second case -- a black panel with one bright line, mean 12 and deviation 30 --
    and it is most of what surf_kitsune is made of, so a rule that caught it would
    repaint that whole map over a property it has on purpose.
    """
    lo, hi, total, n = 255, 0, 0, 0
    for i in range(0, len(rgba) - 3, 4 * stride):
        for k in range(3):
            v = rgba[i + k]
            lo = min(lo, v)
            hi = max(hi, v)
            total += v
            n += 1
    if n == 0:
        return False
    return hi - lo <= 4 and total / n <= 16.0
