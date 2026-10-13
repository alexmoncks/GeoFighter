#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
"""preview.py - draws the poses on the PC, to tune models and animations

Reads out/gen.json (tools/gen_fighter.py) and paints the scene the way geo3d
does (project, cull back faces, flat shade, painter's order), in floating
point: close to the cartridge's picture, not identical to it.

  preview.py sheet [char]     out/preview_sheet<char>.png: every pose, looking right
  preview.py scene P0 P1 X0 X1 [name]   one frame: poses and x of both fighters
"""
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "out")
G = json.load(open(os.path.join(OUT, "gen.json")))
V = G["view"]
W, H, F, CX, CY, ZN = V["W"], V["H"], V["F"], V["CX"], V["CY"], V["ZNEAR"]
Q = 16384.0

def png(path, w, h, rgb):
    raw = b"".join(b"\0" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

def xform(rec, v, dx=0):
    m = rec[:9]
    return [(m[0] * v[0] + m[1] * v[1] + m[2] * v[2]) / Q + rec[9] + dx,
            (m[3] * v[0] + m[4] * v[1] + m[5] * v[2]) / Q + rec[10],
            (m[6] * v[0] + m[7] * v[1] + m[8] * v[2]) / Q + rec[11]]

def fill(buf, pts, col):
    ys = [p[1] for p in pts]
    for y in range(max(0, int(min(ys) + 0.999)), min(H - 1, int(max(ys))) + 1):
        xs = []
        for i in range(len(pts)):
            (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % len(pts)]
            if y0 == y1:
                continue
            if min(y0, y1) <= y <= max(y0, y1):
                xs.append(x0 + (x1 - x0) * (y - y0) / (y1 - y0))
        if xs:
            for x in range(max(0, int(min(xs))), min(W - 1, int(max(xs))) + 1):
                buf[y * W + x] = col

def draw_faces(buf, cam, first, last, light):
    """cam: camera-space vertex per index (None: hidden); faces first..last-1"""
    todo = []
    for fi in range(first, last):
        idx, n, base = G["faces"][fi]
        p = [cam[i] for i in idx]
        if any(q is None or q[2] < ZN for q in p):
            continue
        a = [p[1][k] - p[0][k] for k in range(3)]
        b = [p[2][k] - p[0][k] for k in range(3)]
        nn = [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
        if nn[0] * p[0][0] + nn[1] * p[0][1] + nn[2] * p[0][2] >= 0:
            continue                        # looks away
        lv = sum(light[k] * n[k] / Q for k in range(3))
        level = min(6, int(7 * max(0.0, lv)))
        todo.append((-sum(q[2] for q in p), fi, [(CX + q[0] * F / q[2], CY - q[1] * F / q[2]) for q in p], base + level))
    for _, _, pts, col in sorted(todo):
        fill(buf, pts, col)

def render(p0, p1, x0, x1, c0=0, c1=1, f0=0, f1=1, camx=0):
    buf = [G["cols"]["sky"][1]] * (W * H)
    hz = G["horizon"] - V["Y0"]
    for y in range(H):
        col = G["cols"]["ground"] if y >= hz else G["cols"]["sky"][0 if y < hz // 3 else 1 if y < 2 * hz // 3 else 2]
        for x in range(W):
            buf[y * W + x] = col
    vs = G["vstream"]
    # the floor: its own RUN
    cam = [None] * G["nvert"]
    fr = G["floor_rec"]
    for i in range(G["ranges"][1][-1][1], G["nvert"]):
        cam[i] = xform(fr, vs[i], -camx)
    cl = [fr[0:3], fr[3:6], fr[6:9]]
    lf = [sum(V["light"][r] * cl[r][k] / Q for r in range(3)) for k in range(3)]   # CAM^T * L
    draw_faces(buf, cam, 0, G["nface_floor"], [v for v in lf])
    # the fighters: every part its own transform, one sort for all the faces
    cam = [None] * G["nvert"]
    for slot, (ch, ps, fc, x) in enumerate(((c0, p0, f0, x0), (c1, p1, f1, x1))):
        if ps is None:
            continue
        recs = G["pose_recs"][ch][ps][fc]
        for part, (a, b) in enumerate(G["ranges"][slot]):
            for i in range(a, b):
                cam[i] = xform(recs[part], vs[i], x - camx)
    draw_faces(buf, cam, G["nface_floor"], G["nface"], V["light"])
    return buf

def to_rgb(buf, w, h):
    pal = G["palette"]
    out = bytearray()
    for c in buf:
        r, g, b = pal[c]
        out += bytes((r * 255 // 31, g * 255 // 31, b * 255 // 31))
    return out

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "sheet"
    if cmd == "sheet":
        ch = int(sys.argv[2]) if len(sys.argv) > 2 else 0
        n = G["poses"]
        cw, chh, cols = 128, 150, 8
        rows = (n + cols - 1) // cols
        sheet = bytearray(cw * cols * chh * rows * 3)
        for i in range(n):
            buf = render(i, None, 0, 0, c0=ch)
            rgb = to_rgb(buf, W, H)
            ox, oy = (i % cols) * cw, (i // cols) * chh
            for y in range(chh):
                sy = y + (H - chh)
                src = (sy * W + (W - cw) // 2) * 3
                dst = ((oy + y) * cw * cols + ox) * 3
                sheet[dst:dst + cw * 3] = rgb[src:src + cw * 3]
        png(os.path.join(OUT, "preview_sheet%d.png" % ch), cw * cols, chh * rows, sheet)
        names = sorted(G["anims"].items(), key=lambda kv: kv[1][0])
        print("sheet: %d poses; " % n + ", ".join("%s %d-%d" % (k, v[0], v[0] + v[1] - 1) for k, v in names))
    else:
        p0, p1, x0, x1 = (int(a) for a in sys.argv[2:6])
        name = sys.argv[6] if len(sys.argv) > 6 else "scene"
        png(os.path.join(OUT, "preview_%s.png" % name), W, H, to_rgb(render(p0, p1, x0, x1), W, H))

if __name__ == "__main__":
    main()
