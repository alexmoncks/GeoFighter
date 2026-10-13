#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
"""gen_fighter.py - models, poses and tables of GEO FIGHTER (run by build.sh)

Everything the Z80 would otherwise compute is worked out here:

- The fighters are rigs of rigid parts (boxes). A pose is a set of joint
  angles; forward kinematics gives each part its rotation and origin.
- The camera never turns, so for every pose, facing and part the complete
  geo3d configuration (matrix C * F * P in Q2.14 and the translation) is
  stored ready to send: 24 bytes. The Z80 only adds the fighter's X.
- The normals are stored already in camera space for the stance, because the
  resident scene (VECTOR RAID's engine.md, 6.3) lights every face in the one
  RUN that draws them all.

Writes out/inc/const.asm, out/inc/tables.asm, out/models.bin, out/palette.bin,
out/pose_<char>_<facing>.bin and out/gen.json (for tools/preview.py).
"""
import json
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "out")
Q = 16384

# ------------------------------------------------------------------ the view
VIEW_Y0 = 20            # rows 0..19 are the status bar
G3_W, G3_H = 256, 192
G3_F = 360
G3_CX, G3_CY = 128, 138
G3_ZNEAR = 16
CAM_Y = 95.0            # eye height
CAM_D = 520.0           # distance to the fighters' plane (z = 0)
CAM_PITCH = 8.0         # degrees, looking down
LIGHT = (-0.45, 0.70, -0.55)    # towards the light, camera space
RING_X = 300            # half width of the ring
RING_Z0, RING_Z1 = -130, 170
RING_H = 14             # height of the platform above the ground
WALK_X = 250            # the fighters' x stays inside +-WALK_X
MIN_SEP = 72            # they never stand closer than this (the guards touch)

# ------------------------------------------------------------------ maths
def rad(a):
    return a * math.pi / 180.0

def rot_x(a):
    c, s = math.cos(rad(a)), math.sin(rad(a))
    return [[1, 0, 0], [0, c, -s], [0, s, c]]

def rot_y(a):
    c, s = math.cos(rad(a)), math.sin(rad(a))
    return [[c, 0, s], [0, 1, 0], [-s, 0, c]]

def rot_z(a):
    c, s = math.cos(rad(a)), math.sin(rad(a))
    return [[c, -s, 0], [s, c, 0], [0, 0, 1]]

IDENT = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

def mmul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]

def mvec(a, v):
    return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]

def vadd(a, b):
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]

def vsub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]

def cross(a, b):
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]

def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

def norm(a):
    n = math.sqrt(dot(a, a)) or 1.0
    return [a[0] / n, a[1] / n, a[2] / n]

def q14(x):
    v = int(round(x * Q))
    return max(-32768, min(32767, v))

def s16(x):
    v = int(round(x))
    assert -32768 <= v <= 32767, v
    return v

# The camera: x right, y up, z into the screen (geo3d's frame), pitched down.
_p = rad(CAM_PITCH)
CAM = [[1, 0, 0],
       [0, math.cos(_p), math.sin(_p)],
       [0, -math.sin(_p), math.cos(_p)]]
FACING = [IDENT, rot_y(180)]    # 0: looks right (+x), 1: looks left

# ------------------------------------------------------------------ models
# A part is a list of prisms in the part's own frame (origin at its joint):
# x forward, y up, z to the fighter's left. A prism is a box whose top and
# bottom rectangles may differ; `cols` gives the colour ramp of its faces
# in the order bottom, top, front (+x), back (-x), left (+z), right (-z).
def prism(y0, y1, b, t, cols, bx=0.0, tx=0.0):
    (hx0, hz0), (hx1, hz1) = b, t
    v = [(bx - hx0, y0, -hz0), (bx + hx0, y0, -hz0), (bx + hx0, y0, hz0), (bx - hx0, y0, hz0),
         (tx - hx1, y1, -hz1), (tx + hx1, y1, -hz1), (tx + hx1, y1, hz1), (tx - hx1, y1, hz1)]
    f = [(0, 1, 2, 3), (4, 5, 6, 7), (1, 2, 6, 5), (0, 3, 7, 4), (3, 2, 6, 7), (0, 1, 5, 4)]
    if not isinstance(cols, (list, tuple)):
        cols = [cols] * 6
    return {"v": [list(p) for p in v], "f": [list(q) for q in f], "c": list(cols)}

def build_part(prisms):
    """-> vertices, faces (4 indices, wound clockwise seen from outside), normals, colours"""
    verts, faces, normals, cols = [], [], [], []
    for pr in prisms:
        base = len(verts)
        cen = [sum(p[i] for p in pr["v"]) / 8.0 for i in range(3)]
        verts += pr["v"]
        for f, c in zip(pr["f"], pr["c"]):
            if c is None:
                continue                    # a face nobody can see
            p = [pr["v"][i] for i in f]
            n = cross(vsub(p[1], p[0]), vsub(p[2], p[0]))
            fc = [sum(q[i] for q in p) / 4.0 for i in range(3)]
            if dot(n, vsub(fc, cen)) < 0:
                f = [f[0], f[3], f[2], f[1]]
                n = [-n[0], -n[1], -n[2]]
            faces.append([base + i for i in f])
            normals.append(norm(n))
            cols.append(c)
    return verts, faces, normals, cols

PARTS = ["pelvis", "torso", "head", "uarm_l", "farm_l", "uarm_r", "farm_r",
         "thigh_l", "shin_l", "thigh_r", "shin_r"]
NPARTS = len(PARTS)

def make_character(spec):
    """spec: sizes and colour ramps -> {"parts": {name: (v, f, n, c)}, "joints": {...}}"""
    w = spec.get("bulk", 1.0)
    c = spec["col"]
    leg_t, leg_s = spec.get("thigh", 42.0), spec.get("shin", 40.0)
    arm_u, arm_f = spec.get("uarm", 28.0), spec.get("farm", 27.0)
    torso_h = spec.get("torso", 46.0)
    sh_z = 19.0 * w
    hip_z = 8.5 * w
    parts = {}
    parts["pelvis"] = build_part([prism(-12, 9, (9 * w, 11 * w), (10 * w, 13 * w), c["pelvis"])])
    parts["torso"] = build_part([prism(0, torso_h, (9.5 * w, 12.5 * w), (11.5 * w, sh_z + 1), c["torso"], tx=1.0)])
    hd = c["head"]
    parts["head"] = build_part([prism(1, 27, (7.5, 7.0), (9.5, 8.5), hd, bx=1.0, tx=1.0)])
    for s, z in (("l", 1), ("r", -1)):
        parts["uarm_" + s] = build_part([prism(-arm_u, 2, (5.0 * w, 5.0 * w), (6.2 * w, 6.2 * w), c["uarm"])])
        # one prism, wider at the fist; the cap at the fist has the fist's colour
        fa = c["farm"]
        parts["farm_" + s] = build_part([prism(-arm_f - 3, 1, (5.8 * w, 5.8 * w), (4.6 * w, 4.6 * w),
                                               [c["fist"], fa, fa, fa, fa, fa])])
        parts["thigh_" + s] = build_part([prism(-leg_t, 3, (6.5 * w, 6.2 * w), (8.5 * w, 7.5 * w), c["thigh"])])
        parts["shin_" + s] = build_part([
            prism(-leg_s, 2, (5.0 * w, 4.8 * w), (6.3 * w, 6.0 * w), c["shin"]),
            prism(-leg_s - 7, -leg_s, (10.5, 5.5 * w), (10.5, 5.5 * w), c["foot"], bx=5.0, tx=5.0)])
    joints = {                      # the joint of each part in its parent's frame
        "torso": ("pelvis", (0, 9, 0)),
        "head": ("torso", (1, torso_h, 0)),
        "uarm_l": ("torso", (1, torso_h - 5, sh_z + 4.5 * w)),
        "uarm_r": ("torso", (1, torso_h - 5, -(sh_z + 4.5 * w))),
        "farm_l": ("uarm_l", (0, -arm_u, 0)),
        "farm_r": ("uarm_r", (0, -arm_u, 0)),
        "thigh_l": ("pelvis", (0, -9, hip_z)),
        "thigh_r": ("pelvis", (0, -9, -hip_z)),
        "shin_l": ("thigh_l", (0, -leg_t, 0)),
        "shin_r": ("thigh_r", (0, -leg_t, 0)),
    }
    return {"parts": parts, "joints": joints, "name": spec["name"]}

# colour ramps: 7 tones each at BASE..BASE+6 of the 256-entry palette
RAMPS = {
    "skin": 8, "gi": 16, "black": 24, "hair": 32, "skin2": 40, "blue": 48,
    "red": 56, "boot": 64, "tile_a": 72, "tile_b": 80, "skirt": 88, "gold": 96,
}
RAMP_RGB = {                       # the brightest tone, 0..31 per channel
    "skin": (31, 22, 15), "gi": (31, 31, 30), "black": (9, 9, 12), "hair": (12, 7, 3),
    "skin2": (24, 15, 9), "blue": (6, 13, 31), "red": (31, 6, 5), "boot": (28, 24, 6),
    "tile_a": (22, 24, 27), "tile_b": (13, 16, 22), "skirt": (20, 6, 6), "gold": (31, 26, 4),
}
FIXED = {                          # single colours
    0: (0, 0, 0), 1: (31, 31, 31), 2: (4, 9, 20), 3: (7, 14, 26), 4: (11, 19, 29),
    5: (5, 12, 7), 6: (31, 29, 0), 7: (31, 4, 2), 104: (3, 3, 5), 105: (16, 17, 19),
    106: (0, 26, 8), 107: (31, 16, 0),
}
COL_BLACK, COL_WHITE, COL_SKY0, COL_SKY1, COL_SKY2, COL_GROUND = 0, 1, 2, 3, 4, 5
COL_YELLOW, COL_RED, COL_BARBG, COL_FRAME, COL_GREEN, COL_ORANGE = 6, 7, 104, 105, 106, 107

def R(name):
    return RAMPS[name]

CHARS = [
    {"name": "RAI", "bulk": 1.0,
     "col": {"pelvis": R("black"), "torso": R("gi"), "skin": R("skin"),
             # bottom, top, front, back, left, right: hair on top and behind
             "head": [R("skin"), R("hair"), R("skin"), R("hair"), R("skin"), R("skin")],
             "uarm": R("gi"), "farm": R("skin"), "fist": R("skin"),
             "thigh": R("gi"), "shin": R("gi"), "foot": R("skin")}},
    {"name": "DAGO", "bulk": 1.22, "thigh": 40.0, "shin": 38.0, "torso": 48.0,
     "col": {"pelvis": R("blue"), "torso": R("skin2"), "skin": R("skin2"),
             "head": R("skin2"),
             "uarm": R("skin2"), "farm": R("skin2"), "fist": R("red"),
             "thigh": R("blue"), "shin": R("red"), "foot": R("boot")}},
]

# ------------------------------------------------------------------ poses
# A pose: root (dx forward, lift, lean rz, twist ry, roll rx) and one (rx, ry,
# rz) per joint. A limb hangs along -y: rz > 0 swings it forward. The torso
# and the head point up: rz < 0 leans them forward.
JOINTS = ["pelvis", "torso", "head", "sh_l", "el_l", "sh_r", "el_r", "hip_l", "kn_l", "hip_r", "kn_r"]
JOINT_OF = {"pelvis": "pelvis", "torso": "torso", "head": "head", "uarm_l": "sh_l", "farm_l": "el_l",
            "uarm_r": "sh_r", "farm_r": "el_r", "thigh_l": "hip_l", "shin_l": "kn_l",
            "thigh_r": "hip_r", "shin_r": "kn_r"}

def pose(base=None, **kw):
    p = {"root": [0.0, 0.0, 0.0, 22.0, 0.0], "air": None}
    for j in JOINTS:
        p[j] = [0.0, 0.0, 0.0]
    if base:
        p = json.loads(json.dumps(base))
    for k, v in kw.items():
        if k == "air":
            p["air"] = v
        elif k == "root":
            p["root"] = list(v) + p["root"][len(v):]
        else:
            p[k] = list(v) + [0.0] * (3 - len(v)) if isinstance(v, (list, tuple)) else [0.0, 0.0, float(v)]
    return p

def lerp(a, b, t):
    p = {"air": b["air"] if t >= 0.5 else a["air"]}
    for k in ["root"] + JOINTS:
        p[k] = [x + (y - x) * t for x, y in zip(a[k], b[k])]
    if a["air"] is not None and b["air"] is not None:
        p["air"] = a["air"] + (b["air"] - a["air"]) * t
    return p

def seq(keys, steps):
    """keys k0, k1, ...; steps[i] poses go from k[i] (excluded) to k[i+1] (included)"""
    out = [keys[0]]
    for i, n in enumerate(steps):
        for s in range(1, n + 1):
            out.append(lerp(keys[i], keys[i + 1], s / n))
    return out

def solve(ch, p):
    """forward kinematics -> {part: (R, origin)} in the fighter's frame (x forward)"""
    dx, lift, lean, twist, roll = p["root"]
    r_root = mmul(rot_y(twist), mmul(rot_z(lean), rot_x(roll)))
    res = {}
    jr = lambda j: mmul(rot_y(p[j][1]), mmul(rot_x(p[j][0]), rot_z(p[j][2])))
    res["pelvis"] = (mmul(r_root, jr("pelvis")), [dx, 0.0, 0.0])
    for part in PARTS[1:]:
        par, off = ch["joints"][part]
        pr, po = res[par]
        res[part] = (mmul(pr, jr(JOINT_OF[part])), vadd(po, mvec(pr, off)))
    # stand on the ground: the lowest vertex at y = 0 (or `air` above it)
    low = min(vadd(o, mvec(r, v))[1] for part, (r, o) in res.items() for v in ch["parts"][part][0])
    dy = -low + (p["air"] or 0.0) + lift
    return {part: (r, [o[0], o[1] + dy, o[2]]) for part, (r, o) in res.items()}

# The stance: a bladed guard, the left side ahead (the far side when looking right).
STANCE = pose(
    root=(0, 0, 0, 24, 0),
    pelvis=(0, 0, 4), torso=(0, 6, -10), head=(0, -8, 6),
    sh_l=(0, 0, 58), el_l=(0, 0, 78), sh_r=(-8, 0, 22), el_r=(0, 0, 112),
    hip_l=(4, 0, 30), kn_l=(0, 0, -34), hip_r=(-4, 0, -16), kn_r=(0, 0, -26))

def build_anims():
    A = {}
    s = STANCE
    # idle: the guard breathes
    up = pose(s, torso=(0, 6, -7), sh_l=(0, 0, 62), el_l=(0, 0, 74), sh_r=(-8, 0, 25), el_r=(0, 0, 108),
              hip_l=(4, 0, 27), kn_l=(0, 0, -28), hip_r=(-4, 0, -13), kn_r=(0, 0, -20))
    A["idle"] = (seq([s, up, s], [2, 2])[:-1], 3, "loop")
    # walk: a shuffle step, forwards; backwards is the same played in reverse
    w1 = pose(s, hip_l=(4, 0, 44), kn_l=(0, 0, -30), hip_r=(-4, 0, -28), kn_r=(0, 0, -14), torso=(0, 6, -12))
    w2 = pose(s, hip_l=(4, 0, 14), kn_l=(0, 0, -22), hip_r=(-4, 0, 4), kn_r=(0, 0, -52), torso=(0, 6, -9))
    wf = seq([s, w1, w2, s], [2, 2, 2])[:-1]
    A["walk_f"] = (wf, 2, "loop")
    A["walk_b"] = ([wf[0]] + wf[:0:-1], 2, "loop")
    # punch: the rear hand straight out, the hips turn into it
    pw = pose(s, root=(0, 0, 0, 30, 0), sh_r=(-6, 0, 10), el_r=(0, 0, 125), torso=(0, 2, -8))
    pe = pose(s, root=(10, 0, 0, 4, 0), torso=(0, -22, -16), head=(0, 14, 10),
              sh_r=(-4, 0, 96), el_r=(0, 0, 4), sh_l=(0, 0, 30), el_l=(0, 0, 118),
              hip_l=(4, 0, 38), kn_l=(0, 0, -44), hip_r=(-4, 0, -26), kn_r=(0, 0, -16))
    A["punch"] = (seq([s, pw, pe, pe, s], [1, 2, 1, 3]), 2, "once")
    # kick: the rear leg, a front kick to the body
    kc = pose(s, root=(0, 0, 0, 12, 0), torso=(0, 4, 2), sh_l=(0, 0, 50), el_l=(0, 0, 90),
              sh_r=(-10, 0, -10), el_r=(0, 0, 70), hip_r=(-4, 0, 86), kn_r=(0, 0, -112),
              hip_l=(4, 0, 8), kn_l=(0, 0, -12))
    ke = pose(kc, root=(6, 0, 0, 6, 0), torso=(0, 4, 14), head=(0, -6, -10),
              hip_r=(-4, 0, 98), kn_r=(0, 0, -8), hip_l=(4, 0, -4), kn_l=(0, 0, -8))
    A["kick"] = (seq([s, kc, ke, ke, kc, s], [2, 2, 1, 2, 2]), 2, "once")
    # guard: both arms in front, a little lower
    g = pose(s, torso=(0, 2, -16), head=(0, -4, 12), sh_l=(6, 0, 66), el_l=(0, 0, 112),
             sh_r=(-6, 0, 58), el_r=(0, 0, 118), hip_l=(4, 0, 38), kn_l=(0, 0, -50),
             hip_r=(-4, 0, -10), kn_r=(0, 0, -42))
    A["guard"] = (seq([s, g], [2]), 2, "hold")
    A["blockhit"] = ([pose(g, root=(-6, 0, 0, 24, 0), torso=(0, 2, -8)), g, g], 2, "once")
    # hit: the head and the chest go back
    h1 = pose(s, root=(-8, 0, 0, 30, 0), torso=(0, 10, 18), head=(0, 0, 20), sh_l=(0, 0, 20), el_l=(0, 0, 40),
              sh_r=(-14, 0, -20), el_r=(0, 0, 50), hip_l=(4, 0, 18), kn_l=(0, 0, -30), hip_r=(-4, 0, -30), kn_r=(0, 0, -20))
    A["hit"] = (seq([s, h1, h1, s], [1, 1, 3]), 2, "once")
    # knocked out: falls on the back and stays there
    f1 = pose(h1, root=(-14, 0, 34, 24, 0), sh_l=(0, 0, 60), sh_r=(-10, 0, 40), hip_l=(4, 0, 40), kn_l=(0, 0, -50))
    f2 = pose(s, root=(-40, 0, 72, 16, 0), torso=(0, 0, 6), head=(0, 0, 10), sh_l=(20, 0, 70), el_l=(0, 0, 30),
              sh_r=(-20, 0, 60), el_r=(0, 0, 30), hip_l=(6, 0, 52), kn_l=(0, 0, -60), hip_r=(-6, 0, 30), kn_r=(0, 0, -30))
    f3 = pose(s, root=(-70, 0, 90, 8, 0), torso=(0, 0, 2), head=(0, 0, 4), sh_l=(30, 0, 20), el_l=(0, 0, 10),
              sh_r=(-30, 0, 12), el_r=(0, 0, 10), hip_l=(8, 0, 12), kn_l=(0, 0, -14), hip_r=(-8, 0, 4), kn_r=(0, 0, -6))
    A["ko"] = (seq([s, h1, f1, f2, f3], [1, 2, 2, 2]), 2, "hold")
    # the winner: stands up, the fist in the air
    v1 = pose(root=(0, 0, 0, 40, 0), torso=(0, 10, 0), head=(0, -20, 0), sh_l=(0, 0, 8), el_l=(0, 0, 12),
              sh_r=(-10, 0, 168), el_r=(0, 0, 14), hip_l=(6, 0, 6), kn_l=(0, 0, -4), hip_r=(-6, 0, -4), kn_r=(0, 0, -4))
    v2 = pose(v1, sh_r=(-10, 0, 150), el_r=(0, 0, 60))
    A["win"] = (seq([s, v1, v2, v1], [3, 2, 2]), 3, "loopend")
    return A

# the moves the game logic knows: the step whose first tick hits, reach, damage
MOVES = {"punch": {"hit_step": 3, "reach": 86, "damage": 9},
         "kick": {"hit_step": 4, "reach": 102, "damage": 14}}
ANIM_ORDER = ["idle", "walk_f", "walk_b", "punch", "kick", "guard", "blockhit", "hit", "ko", "win"]
REC = 24                           # bytes per part: 9 matrix words, 3 translation words
POSE_BYTES = REC * NPARTS

# ------------------------------------------------------------------ the floor
def build_floor():
    nx, nz = 6, 2
    xs = [-RING_X + i * (2 * RING_X) / nx for i in range(nx + 1)]
    zs = [RING_Z0 + j * (RING_Z1 - RING_Z0) / nz for j in range(nz + 1)]
    verts = [[x, 0.0, z] for z in zs for x in xs]
    faces, normals, cols = [], [], []
    for j in range(nz):
        for i in range(nx):
            a = j * (nx + 1) + i
            f = [a, a + 1, a + nx + 2, a + nx + 1]
            p = [verts[k] for k in f]
            if cross(vsub(p[1], p[0]), vsub(p[2], p[0]))[1] < 0:
                f = [f[0], f[3], f[2], f[1]]
            faces.append(f)
            normals.append([0.0, 1.0, 0.0])
            cols.append(R("tile_a") if (i + j) % 2 == 0 else R("tile_b"))
    b = len(verts)
    verts += [[-RING_X, -RING_H, RING_Z0], [RING_X, -RING_H, RING_Z0]]
    f = [0, nx, b + 1, b]                   # the front of the platform
    p = [verts[k] for k in f]
    if cross(vsub(p[1], p[0]), vsub(p[2], p[0]))[2] > 0:
        f = [f[0], f[3], f[2], f[1]]
    faces.append(f)
    normals.append([0.0, 0.0, -1.0])
    cols.append(R("skirt"))
    return verts, faces, normals, cols

# ------------------------------------------------------------------ output
def cam_t(o):
    """translation for a part whose origin is o in the world, camera at x = 0"""
    return mvec(CAM, [o[0], o[1] - CAM_Y, o[2] + CAM_D])

def pose_record(ch, p):
    """-> 2 facings x NPARTS x (9 matrix words, 3 translation words)"""
    sol = solve(ch, p)
    out = []
    for f in (0, 1):
        recs = []
        for part in PARTS:
            r, o = sol[part]
            m = mmul(CAM, mmul(FACING[f], r))
            t = cam_t(mvec(FACING[f], o))
            recs.append([q14(m[i][j]) for i in range(3) for j in range(3)] + [s16(t[0]), s16(t[1]), s16(t[2])])
        out.append(recs)
    return out, sol

def main():
    os.makedirs(os.path.join(OUT, "inc"), exist_ok=True)
    chars = [make_character(s) for s in CHARS]
    anims = build_anims()

    # the poses, shared by the characters (each has its own records: the
    # limbs differ in length)
    poses, anim_steps = [], {}
    for name in ANIM_ORDER:
        plist, ticks, mode = anims[name]
        anim_steps[name] = (len(poses), len(plist), ticks, mode)
        poses += plist
    assert len(poses) * POSE_BYTES <= 16384, "the poses of a facing must fit one bank"

    gen = {"view": {"W": G3_W, "H": G3_H, "F": G3_F, "CX": G3_CX, "CY": G3_CY, "ZNEAR": G3_ZNEAR,
                    "Y0": VIEW_Y0, "light": norm(LIGHT)},
           "chars": [], "poses": len(poses), "anims": anim_steps, "parts": PARTS}

    # ---- vertex and face streams: fighter 0, fighter 1, the floor (highest,
    # so its RUN transforms every vertex and a hide RUN can put all of them
    # behind the near plane)
    vstream, ranges = [], []           # ranges[slot][part] = (first, end)
    fighter_faces = []
    stance_sol = None
    for slot, ch in enumerate(chars):
        sol = solve(ch, STANCE)
        rr, ff = [], []
        for part in PARTS:
            v, f, n, c = ch["parts"][part]
            first = len(vstream)
            vstream += v
            rr.append((first, len(vstream)))
            rest = mmul(CAM, mmul(FACING[slot], sol[part][0]))     # slot 0 looks right, slot 1 left
            for fi, ni, ci in zip(f, n, c):
                ff.append(([first + i for i in fi], mvec(rest, ni), ci))
        ranges.append(rr)
        fighter_faces.append(ff)
    fv, ff_, fn, fc = build_floor()
    floor_first = len(vstream)
    vstream += fv
    nvert = len(vstream)
    floor_faces = [([floor_first + i for i in f], n, c) for f, n, c in zip(ff_, fn, fc)]
    all_faces = floor_faces + fighter_faces[0] + fighter_faces[1]     # the floor first: its RUN draws faces 0..NF-1
    assert nvert <= 255 and len(all_faces) <= 255, (nvert, len(all_faces))

    vbin = b"".join(struct.pack("<3h", s16(x), s16(y), s16(z)) for x, y, z in vstream)
    fbin = b""
    for idx, n, c in all_faces:
        fbin += bytes(idx) + struct.pack("<3h", q14(n[0]), q14(n[1]), q14(n[2])) + bytes([c])
    with open(os.path.join(OUT, "models.bin"), "wb") as f:
        f.write(vbin + fbin)

    # ---- the palette: 256 x (R, G, B), 5 bits each
    pal = [(0, 0, 0)] * 256
    pal = list(pal)
    for k, rgb in FIXED.items():
        pal[k] = rgb
    for name, basei in RAMPS.items():
        r, g, b = RAMP_RGB[name]
        for t in range(7):
            s = 0.30 + 0.70 * t / 6.0
            pal[basei + t] = (int(round(r * s)), int(round(g * s)), int(round(b * s)))
    with open(os.path.join(OUT, "palette.bin"), "wb") as f:
        f.write(bytes(v for rgb in pal for v in rgb))

    # ---- pose records: one file per character and facing (one bank each)
    sols = []
    for ci, ch in enumerate(chars):
        data = [b"", b""]
        chsol = []
        for p in poses:
            recs, sol = pose_record(ch, p)
            chsol.append(recs)
            for f in (0, 1):
                for rec in recs[f]:
                    data[f] += struct.pack("<12h", *rec)
        for f in (0, 1):
            with open(os.path.join(OUT, "pose_%d_%d.bin" % (ci, f)), "wb") as fo:
                fo.write(data[f])
        sols.append(chsol)

    # ---- the floor's own matrix (the camera) and translation
    ft = cam_t([0.0, 0.0, 0.0])
    floor_rec = [q14(CAM[i][j]) for i in range(3) for j in range(3)] + [s16(ft[0]), s16(ft[1]), s16(ft[2])]

    L = norm(LIGHT)
    with open(os.path.join(OUT, "inc", "const.asm"), "w") as f:
        w = lambda s: f.write(s + "\n")
        w("; generated by tools/gen_fighter.py")
        w("ROM_BANKS:   equ 8")
        w("POSE_BANK0:  equ 2               ; + 2 * character + facing")
        w("G3_W:        equ %d" % G3_W)
        w("G3_H:        equ %d" % G3_H)
        w("G3_F:        equ %d" % G3_F)
        w("G3_CX:       equ %d" % G3_CX)
        w("G3_CY:       equ %d" % G3_CY)
        w("G3_ZNEAR:    equ %d" % G3_ZNEAR)
        w("VIEW_Y0:     equ %d" % VIEW_Y0)
        w("HORIZON:     equ %d             ; screen row of the horizon" % (VIEW_Y0 + int(round(G3_CY - G3_F * math.tan(_p)))))
        w("NVERT_ALL:   equ %d" % nvert)
        w("NFACE_ALL:   equ %d" % len(all_faces))
        w("NFACE_FLOOR: equ %d" % len(floor_faces))
        w("NPARTS:      equ %d" % NPARTS)
        w("POSE_REC:    equ %d             ; bytes per part" % REC)
        w("POSE_BYTES:  equ %d            ; bytes per pose" % POSE_BYTES)
        w("VTX_BYTES:   equ %d" % len(vbin))
        w("FACE_BYTES:  equ %d" % len(fbin))
        w("LIGHT_X:     equ %d" % q14(L[0]))
        w("LIGHT_Y:     equ %d" % q14(L[1]))
        w("LIGHT_Z:     equ %d" % q14(L[2]))
        w("WALK_X:      equ %d" % WALK_X)
        w("MIN_SEP:     equ %d" % MIN_SEP)
        for k, v in (("COL_BLACK", COL_BLACK), ("COL_WHITE", COL_WHITE), ("COL_SKY0", COL_SKY0),
                     ("COL_SKY1", COL_SKY1), ("COL_SKY2", COL_SKY2), ("COL_GROUND", COL_GROUND),
                     ("COL_YELLOW", COL_YELLOW), ("COL_RED", COL_RED), ("COL_BARBG", COL_BARBG),
                     ("COL_FRAME", COL_FRAME), ("COL_GREEN", COL_GREEN), ("COL_ORANGE", COL_ORANGE)):
            w("%s:%s equ %d" % (k, " " * (12 - len(k)), v))
        for i, name in enumerate(ANIM_ORDER):
            w("AN_%s:%s equ %d" % (name.upper(), " " * (9 - len(name)), i))
        for name, mv in MOVES.items():
            w("MV_%s_STEP:  equ %d" % (name.upper(), mv["hit_step"]))
            w("MV_%s_REACH: equ %d" % (name.upper(), mv["reach"]))
            w("MV_%s_DMG:   equ %d" % (name.upper(), mv["damage"]))

    with open(os.path.join(OUT, "inc", "tables.asm"), "w") as f:
        w = lambda s: f.write(s + "\n")
        w("; generated by tools/gen_fighter.py")
        w("; the end of each part's vertex range, per slot, in drawing (RUN) order:")
        w("; the highest range first")
        for slot in (0, 1):
            w("part_end_%d:" % slot)
            w("        db " + ", ".join(str(ranges[slot][i][1]) for i in range(NPARTS)))
        w("floor_rec:")
        w("        dw " + ", ".join(str(v) for v in floor_rec))
        w("; animations: first pose, steps, ticks per step, mode (0 loop, 1 once, 2 hold, 3 loop the last 4)")
        w("anim_tab:")
        modes = {"loop": 0, "once": 1, "hold": 2, "loopend": 3}
        for name in ANIM_ORDER:
            first, n, ticks, mode = anim_steps[name]
            w("        db %d, %d, %d, %d      ; %s" % (first, n, ticks, modes[mode], name))

    # ---- everything the preview needs
    gen["nvert"], gen["nface"], gen["nface_floor"] = nvert, len(all_faces), len(floor_faces)
    gen["vstream"] = [[s16(c) for c in v] for v in vstream]
    gen["faces"] = [[idx, [q14(x) for x in n], c] for idx, n, c in all_faces]
    gen["ranges"] = ranges
    gen["floor_rec"] = floor_rec
    gen["pose_recs"] = sols                     # [char][pose][facing][part] -> 12 words
    gen["palette"] = pal
    gen["cols"] = {"sky": [COL_SKY0, COL_SKY1, COL_SKY2], "ground": COL_GROUND}
    gen["horizon"] = VIEW_Y0 + int(round(G3_CY - G3_F * math.tan(_p)))
    with open(os.path.join(OUT, "gen.json"), "w") as f:
        json.dump(gen, f)
    print("gen_fighter: %d vertices, %d faces (%d floor), %d poses (%d bytes each), %d animations" %
          (nvert, len(all_faces), len(floor_faces), len(poses), POSE_BYTES, len(ANIM_ORDER)))

if __name__ == "__main__":
    main()
