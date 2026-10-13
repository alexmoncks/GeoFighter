#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
"""preview.py - draws the scene on the PC, to tune models, poses and cameras

Reads out/gen.json (tools/gen_fighter.py) and paints the scene the way geo3d
does (project, cull back faces, flat shade, painter's order), in floating
point: close to the cartridge's picture, not identical to it.

  preview.py sheet [char]     out/preview_sheet<char>.png: every pose, looking right
  preview.py scene P0 P1 X0 X1 [name]   one fight frame: poses and x of both fighters
  preview.py orbit [n]        out/preview_orbit.png: n frames of the opening shot (default 12)
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
K = [k / Q for k in G["kvec"]]

def png(path, w, h, rgb):
    raw = b"".join(b"\0" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

def xform(rec, v, dx=0.0):
    m = rec[:9]
    return [(m[0] * v[0] + m[1] * v[1] + m[2] * v[2]) / Q + rec[9] + dx * K[0],
            (m[3] * v[0] + m[4] * v[1] + m[5] * v[2]) / Q + rec[10] + dx * K[1],
            (m[6] * v[0] + m[7] * v[1] + m[8] * v[2]) / Q + rec[11] + dx * K[2]]

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

def draw_faces(buf, cam, first, last, lm):
    """cam: camera-space vertex per index (None: hidden); lm: the light against the stored normals"""
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
        level = min(6, int(7 * max(0.0, sum(lm[k] * n[k] / Q for k in range(3)))))
        todo.append((-sum(q[2] for q in p), fi, [(CX + q[0] * F / q[2], CY - q[1] * F / q[2]) for q in p], base + level))
    for _, _, pts, col in sorted(todo):
        fill(buf, pts, col)

LM = [v / Q for v in G["light0"]]           # every RUN lights with this (see gen_fighter.light)

def render(p0, p1, x0, x1, c0=0, c1=1, f0=0, f1=1, camx=0):
    buf = [G["ground"]] * (W * H)
    vs = G["vfight"]
    cam = [None] * G["nvert"]
    for i in range(G["nv_fight"], G["nvert"]):
        cam[i] = xform(G["ring_rec"], vs[i], -camx)
    draw_faces(buf, cam, 0, G["nface_ring"], LM)
    cam = [None] * G["nvert"]
    for slot, (ch, ps, fc, x) in enumerate(((c0, p0, f0, x0), (c1, p1, f1, x1))):
        if ps is None:
            continue
        recs = G["pose_recs"][ch][ps][fc]
        for part, (a, b) in enumerate(G["ranges"][slot]):
            for i in range(a, b):
                cam[i] = xform(recs[part], vs[i], x - camx)
    draw_faces(buf, cam, G["nface_ring"], G["nface"], LM)
    return buf

def render_orbit(i):
    buf = [G["ground"]] * (W * H)
    rec, _ = G["orbit"][i]
    cam = [xform(rec, v) for v in G["vintro"]]
    ring = [c if k >= G["nv_fight"] else None for k, c in enumerate(cam)]
    draw_faces(buf, ring, 0, G["nface_ring"], LM)
    men = [c if k < G["nv_fight"] else None for k, c in enumerate(cam)]
    draw_faces(buf, men, G["nface_ring"], G["nface"], LM)
    return buf

def to_rgb(buf):
    pal = G["palette"]
    out = bytearray()
    for c in buf:
        r, g, b = pal[c]
        out += bytes((r * 255 // 31, g * 255 // 31, b * 255 // 31))
    return out

def sheet(frames, cols, cw, chh, x0, y0, path):
    rows = (len(frames) + cols - 1) // cols
    out = bytearray(cw * cols * chh * rows * 3)
    for i, buf in enumerate(frames):
        rgb = to_rgb(buf)
        ox, oy = (i % cols) * cw, (i // cols) * chh
        for y in range(chh):
            src = ((y0 + y) * W + x0) * 3
            dst = ((oy + y) * cw * cols + ox) * 3
            out[dst:dst + cw * 3] = rgb[src:src + cw * 3]
    png(path, cw * cols, chh * rows, out)

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "sheet"
    if cmd == "sheet":
        ch = int(sys.argv[2]) if len(sys.argv) > 2 else 0
        n = G["poses"]
        sheet([render(i, None, 0, 0, c0=ch) for i in range(n)], 8, 128, 150, 64, 20,
              os.path.join(OUT, "preview_sheet%d.png" % ch))
        names = sorted(G["anims"].items(), key=lambda kv: kv[1][0])
        print("sheet: %d poses; " % n + ", ".join("%s %d-%d" % (k, v[0], v[0] + v[1] - 1) for k, v in names))
    elif cmd == "orbit":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else 12
        total = len(G["orbit"])
        idx = [min(total - 1, int(round(i * (total - 1) / (n - 1)))) for i in range(n)]
        sheet([render_orbit(i) for i in idx], 4, W, H, 0, 0, os.path.join(OUT, "preview_orbit.png"))
        print("orbit frames:", idx)
    else:
        p0, p1, x0, x1 = (int(a) for a in sys.argv[2:6])
        name = sys.argv[6] if len(sys.argv) > 6 else "scene"
        png(os.path.join(OUT, "preview_%s.png" % name), W, H, to_rgb(render(p0, p1, x0, x1)))

if __name__ == "__main__":
    main()
