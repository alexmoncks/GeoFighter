#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Alex Moncks
"""gen_fighter.py - models, poses and tables of GEO FIGHTER (run by build.sh)

Everything the Z80 would otherwise compute is worked out here:

- The fighters are rigs of rigid parts. A pose is a set of joint angles;
  forward kinematics gives each part its rotation and origin.
- In a fight the camera never turns (it only slides along the ring), so for
  every pose, facing and part the complete geo3d configuration (matrix
  C0 * F * P in Q2.14 and the translation) is stored ready to send: 24
  bytes. The Z80 adds the fighter's position along the ring times one
  constant vector.
- The opening shot circles the ring once and closes in. Nothing moves in it
  but the camera, so the fighters are stored a second time with their
  vertices already in the world (the stance, at their marks) and each frame
  is ONE camera record for the whole scene.
- A sidestep turns the fight's axis. The fighters are still drawn along
  the same line with the same pose records: it is the ring that is drawn
  turned under them, with one matrix (and its light) for each of the
  AXIS_N notches of a full turn.
- All normals are stored in the fight camera's space; the light register is
  set so that every RUN lights the faces the same way (see light()).

Writes out/inc/const.asm, out/inc/tables.asm, out/models.bin (fight
vertices, then the faces), out/vtx_intro.bin, out/orbit.bin,
out/ring_tab.bin, out/palette.bin, out/pose_<char>_<facing>_<half>.bin
(POSES_BANK poses, a 16 KB bank, in each half) and out/gen.json (for
tools/preview.py).
"""
import json
import math
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "out")
Q = 16384

# ------------------------------------------------------------------ the view
VIEW_Y0 = 20            # rows 0..19 are the status bar
G3_W, G3_H = 256, 192
G3_F = 360
G3_CX, G3_CY = 128, 104 # where the camera's target lands in the view
G3_ZNEAR = 16
TARGET = (0.0, 62.0, 0.0)       # what the camera looks at: the fighters' waists
CAM_YAW = 28.0          # the fight camera: turned to see the ring at an angle
CAM_PITCH = 24.0        # ... from above
CAM_DIST = 560.0
ORBIT_N = 120           # frames of the opening shot (4 seconds)
ORBIT_DIST = 1150.0     # where it starts: far
ORBIT_PITCH = 38.0      # ... and high
LIGHT_W = (-0.35, 0.80, -0.48)  # towards the light, in the world
RING = 240              # half the side of the (square) ring
RING_H = 20             # height of the platform
WALK_X = 190            # the fighters' x stays inside +-WALK_X
MARK_X = 64             # where they stand when the round starts
MIN_SEP = 72            # they never stand closer than this (the guards touch)
CAM_MAX = 96            # how far the fight camera slides to follow them
AXIS_N = 128            # steps of a full turn of the fight's axis (the ring turns under the fighters)
STEP_TURN = 8           # ... and how many a sidestep takes: 22.5 degrees
POSES_BANK = 62         # poses in a 16 KB bank

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

def camera(yaw, pitch, dist):
    """-> (C, position): geo3d's frame is x right, y up, z into the screen.
    The rows of C are the camera's right, up and forward in the world."""
    cy, sy, cp, sp = math.cos(rad(yaw)), math.sin(rad(yaw)), math.cos(rad(pitch)), math.sin(rad(pitch))
    fwd = [sy * cp, -sp, cy * cp]
    c = [[cy, 0.0, -sy], [sy * sp, cp, cy * sp], fwd]
    return c, [TARGET[i] - dist * fwd[i] for i in range(3)]

C0, CAM0 = camera(CAM_YAW, CAM_PITCH, CAM_DIST)
KVEC = [C0[0][0], C0[1][0], C0[2][0]]       # one unit along the world's x, seen by the fight camera
LIGHT0 = mvec(C0, norm(LIGHT_W))            # the light in the fight camera's space
FACING = [IDENT, rot_y(180)]                # 0: looks right (+x), 1: looks left

def light(rot):
    """The light register for a RUN whose matrix is `rot`. geo3d lights a
    face with transpose(rot) * register against the stored normal, and the
    normals are stored in the fight camera's space: the register is rot * LIGHT0."""
    return [q14(v) for v in mvec(rot, LIGHT0)]

# ------------------------------------------------------------------ models
# A part is made of pieces in the part's own frame (origin at its joint):
# x forward, y up, z to the fighter's left.
def tube(rings, sides, caps):
    """Stacked rectangles sharing their vertices: rings = [(y, hx, hz, cx)]
    from the bottom up; sides = one colour per segment, or [front, back,
    left, right]; caps = (bottom, top) colours, None for no cap."""
    v = []
    for y, hx, hz, cx in rings:
        v += [[cx - hx, y, -hz], [cx + hx, y, -hz], [cx + hx, y, hz], [cx - hx, y, hz]]
    f = []
    for s in range(len(rings) - 1):
        a, b = 4 * s, 4 * s + 4
        col = sides[s] if isinstance(sides[s], (list, tuple)) else [sides[s]] * 4
        axis = [(rings[s][3] + rings[s + 1][3]) / 2.0, (rings[s][0] + rings[s + 1][0]) / 2.0, 0.0]
        f += [([a + 1, a + 2, b + 2, b + 1], col[0], axis), ([a, a + 3, b + 3, b], col[1], axis),
              ([a + 3, a + 2, b + 2, b + 3], col[2], axis), ([a, a + 1, b + 1, b], col[3], axis)]
    top = 4 * (len(rings) - 1)
    mid = [sum(r[3] for r in rings) / len(rings), (rings[0][0] + rings[-1][0]) / 2.0, 0.0]
    if caps[0] is not None:
        f.append(([0, 1, 2, 3], caps[0], mid))
    if caps[1] is not None:
        f.append(([top, top + 1, top + 2, top + 3], caps[1], mid))
    return v, f

OCT = 8                 # sides of the rounded tubes (geo3d v2.0 holds 1023 vertices)

def side_colour(sides, k, n):
    """the colour of side k of n: one colour, or [front, back, left, right];
    a side between two of those takes the front's or the back's"""
    if not isinstance(sides, (list, tuple)):
        return sides
    a = (360.0 * k / n) % 360.0                 # the direction the side faces
    if a < 45.0 or a > 315.0:
        return sides[0]
    if 135.0 < a < 225.0:
        return sides[1]
    if a == 90.0:
        return sides[2]
    if a == 270.0:
        return sides[3]
    return sides[0] if (a < 90.0 or a > 270.0) else sides[1]

def otube(rings, sides, caps):
    """A rounded tube: octagons sharing their vertices, rings = [(y, hx, hz,
    cx)] from the bottom up, each octagon as wide as the rectangle of tube()
    (its flat sides touch x = cx +- hx and z = +- hz). Side k faces 45 * k
    degrees from the front (+x) towards the left (+z). sides: one colour per
    segment, or [front, back, left, right]; caps: (bottom, top), None for
    none; a cap is 3 quads."""
    n = OCT
    s = 1.0 / math.cos(math.pi / n)
    v = []
    for y, hx, hz, cx in rings:
        for k in range(n):
            t = 2.0 * math.pi * (k - 0.5) / n
            v.append([cx + hx * s * math.cos(t), y, hz * s * math.sin(t)])
    f = []
    for r in range(len(rings) - 1):
        a, b = n * r, n * r + n
        axis = [(rings[r][3] + rings[r + 1][3]) / 2.0, (rings[r][0] + rings[r + 1][0]) / 2.0, 0.0]
        for k in range(n):
            k1 = (k + 1) % n
            f.append(([a + k, a + k1, b + k1, b + k], side_colour(sides[r], k, n), axis))
    mid = [sum(q[3] for q in rings) / len(rings), (rings[0][0] + rings[-1][0]) / 2.0, 0.0]
    for c, base in ((caps[0], 0), (caps[1], n * (len(rings) - 1))):
        if c is not None:
            o = lambda i: base + i
            f += [([o(0), o(1), o(2), o(3)], c, mid), ([o(0), o(3), o(4), o(7)], c, mid),
                  ([o(4), o(5), o(6), o(7)], c, mid)]
    return v, f

def wedge(x0, x1, xt, y0, y1, hz, col):
    """A foot: the sole from x0 to x1 at y0, rising to an edge at (xt, y1)."""
    v = [[x0, y0, -hz], [x1, y0, -hz], [x1, y0, hz], [x0, y0, hz], [xt, y1, -hz], [xt, y1, hz]]
    mid = [sum(p[i] for p in v) / 6.0 for i in range(3)]
    f = [([0, 1, 2, 3], col, mid), ([0, 3, 5, 4], col, mid), ([1, 2, 5, 4], col, mid),
         ([3, 2, 5, 5], col, mid), ([0, 1, 4, 4], col, mid)]
    return v, f

def build_part(pieces):
    """-> vertices, faces (4 indices, clockwise seen from outside; a triangle
    repeats its last vertex), unit normals, colours"""
    verts, faces, normals, cols = [], [], [], []
    for v, f in pieces:
        base = len(verts)
        verts += v
        for idx, col, ref in f:
            p = [v[i] for i in idx]
            n = cross(vsub(p[1], p[0]), vsub(p[2], p[0]))
            fc = [sum(q[i] for q in p) / 4.0 for i in range(3)]
            if dot(n, vsub(fc, ref)) < 0:
                idx = [idx[0], idx[2], idx[1], idx[1]] if idx[2] == idx[3] else [idx[0], idx[3], idx[2], idx[1]]
                n = [-n[0], -n[1], -n[2]]
            faces.append([base + i for i in idx])
            normals.append(norm(n))
            cols.append(col)
    return verts, faces, normals, cols

PARTS = ["pelvis", "torso", "head", "uarm_l", "farm_l", "uarm_r", "farm_r",
         "thigh_l", "shin_l", "thigh_r", "shin_r"]
NPARTS = len(PARTS)

def make_character(spec):
    w = spec.get("bulk", 1.0)
    c = spec["col"]
    leg_t, leg_s = spec.get("thigh", 42.0), spec.get("shin", 40.0)
    arm_u, arm_f = spec.get("uarm", 28.0), spec.get("farm", 27.0)
    th = spec.get("torso", 46.0)
    sh_z = 19.0 * w
    hip_z = 8.5 * w
    parts = {}
    # rounded (octagonal) tubes, with more rings than the boxes of the first
    # demo: the same outline, now with a belly, a chest, a neck, cheeks, a
    # forehead, a biceps, a calf
    parts["pelvis"] = build_part([otube(
        [(-12, 9.0 * w, 11.0 * w, 0), (-3, 10.0 * w, 12.6 * w, 0), (9, 10.0 * w, 13.0 * w, 0)],
        [c["pelvis"], c["pelvis"]], (c["pelvis"], c["pelvis"]))])
    # the waist, the belt, the belly, the chest (the deepest), the shoulders
    # (the widest), the trapezius
    parts["torso"] = build_part([otube(
        [(0, 9.4 * w, 11.8 * w, 0.0), (6, 9.8 * w, 12.4 * w, 0.5), (th * 0.35, 10.6 * w, 13.6 * w, 1.4),
         (th * 0.62, 12.4 * w, 15.8 * w, 2.6), (th * 0.86, 11.2 * w, sh_z + 0.5, 2.0),
         (th, 7.4 * w, sh_z - 4.0 * w, 1.0)],
        [c["belt"], c["torso"], c["torso"], c["torso"], c["torso"]], (c["belt"], c["torso"]))])
    # the neck, the chin, the jaw, the cheeks, the temples, the forehead, the crown
    parts["head"] = build_part([otube(
        [(-1, 3.8, 3.8, 0.5), (3, 4.2, 4.0, 0.8), (5, 6.0, 5.4, 2.2), (11, 8.6, 7.8, 1.6),
         (18, 9.0, 8.4, 1.0), (24, 8.2, 7.8, 0.4), (28.5, 5.6, 5.4, 0.0)],
        [c["skin"], c["skin"], c["jaw"], c["face"], c["face"], c["crown"]], (c["skin"], c["crown"]))])
    for s in ("l", "r"):
        # the elbow, the biceps, the shoulder
        parts["uarm_" + s] = build_part([otube(
            [(-arm_u, 4.6 * w, 4.6 * w, 0), (-arm_u * 0.55, 5.6 * w, 5.6 * w, 0.6),
             (-arm_u * 0.15, 6.2 * w, 6.0 * w, 0.3), (2, 6.6 * w, 6.4 * w, 0)],
            [c["uarm"]] * 3, (c["uarm"], c["uarm"]))])
        # the wrist (thin), the forearm, the elbow; the fist, a block
        parts["farm_" + s] = build_part([
            otube([(-arm_f + 5, 4.0 * w, 4.2 * w, 0), (-arm_f * 0.45, 5.4 * w, 5.2 * w, 0.4),
                   (-4, 5.6 * w, 5.4 * w, 0.2), (1, 5.0 * w, 5.0 * w, 0)],
                  [c["farm"]] * 3, (None, c["farm"])),
            tube([(-arm_f - 5, 5.4 * w, 5.0 * w, 0.5), (-arm_f + 1, 6.2 * w, 5.6 * w, 0.3),
                  (-arm_f + 6, 4.6 * w, 4.4 * w, 0)],
                 [c["fist"], c["fist"]], (c["fist"], c["fist"]))])
        # the knee, the thigh, the hip
        parts["thigh_" + s] = build_part([otube(
            [(-leg_t, 6.2 * w, 6.0 * w, 0.5), (-leg_t * 0.5, 7.8 * w, 7.2 * w, 1.2),
             (-leg_t * 0.15, 8.6 * w, 7.8 * w, 0.6), (3, 8.8 * w, 8.0 * w, 0)],
            [c["thigh"]] * 3, (c["thigh"], c["thigh"]))])
        # the ankle, the calf (behind), the knee; the foot
        parts["shin_" + s] = build_part([
            otube([(-leg_s, 4.4 * w, 4.4 * w, 0), (-leg_s * 0.55, 5.6 * w, 5.4 * w, -0.6),
                   (-leg_s * 0.2, 6.4 * w, 6.0 * w, -1.0), (2, 6.4 * w, 6.0 * w, 0)],
                  [c["shin"]] * 3, (c["shin"], c["shin"])),
            wedge(-7.0, 17.0, 0.0, -leg_s - 7, -leg_s + 2, 5.4 * w, c["foot"])])
    joints = {                      # the joint of each part in its parent's frame
        "torso": ("pelvis", (0, 9, 0)),
        "head": ("torso", (1, th, 0)),
        "uarm_l": ("torso", (1, th - 5, sh_z + 4.5 * w)),
        "uarm_r": ("torso", (1, th - 5, -(sh_z + 4.5 * w))),
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
    "tile_a": (23, 25, 28), "tile_b": (12, 15, 22), "skirt": (22, 5, 5), "gold": (31, 26, 4),
}
FIXED = {                          # single colours
    0: (0, 0, 0), 1: (31, 31, 31), 5: (3, 7, 9), 6: (31, 29, 0), 7: (31, 4, 2),
    104: (3, 3, 5), 105: (16, 17, 19), 106: (0, 26, 8), 107: (31, 16, 0),
}
COL_BLACK, COL_WHITE, COL_GROUND = 0, 1, 5
COL_YELLOW, COL_RED, COL_BARBG, COL_FRAME, COL_GREEN, COL_ORANGE = 6, 7, 104, 105, 106, 107

def R(name):
    return RAMPS[name]

SK, HR, BK = R("skin"), R("hair"), R("black")
S2 = R("skin2")
CHARS = [
    {"name": "RAI", "bulk": 1.0,
     "col": {"pelvis": R("gi"), "belt": BK, "torso": R("gi"), "skin": SK,
             # sides are front, back, left, right: the hair behind and on the sides
             "jaw": SK, "face": [SK, HR, HR, HR], "crown": HR,
             "uarm": R("gi"), "farm": SK, "fist": SK,
             "thigh": R("gi"), "shin": R("gi"), "foot": SK}},
    {"name": "DAGO", "bulk": 1.22, "thigh": 40.0, "shin": 38.0, "torso": 48.0,
     "col": {"pelvis": R("blue"), "belt": R("gold"), "torso": S2, "skin": S2,
             "jaw": [BK, S2, BK, BK], "face": S2, "crown": S2,       # a beard, no hair
             "uarm": S2, "farm": S2, "fist": R("red"),
             "thigh": R("blue"), "shin": R("red"), "foot": R("boot")}},
]

# ------------------------------------------------------------------ poses
# A pose: root (dx forward, lift, lean rz, twist ry, roll rx, dz to the left)
# and one (rx, ry, rz) per joint. A limb hangs along -y: rz > 0 swings it forward. The torso
# and the head point up: rz < 0 leans them forward.
JOINTS = ["pelvis", "torso", "head", "sh_l", "el_l", "sh_r", "el_r", "hip_l", "kn_l", "hip_r", "kn_r"]
JOINT_OF = {"pelvis": "pelvis", "torso": "torso", "head": "head", "uarm_l": "sh_l", "farm_l": "el_l",
            "uarm_r": "sh_r", "farm_r": "el_r", "thigh_l": "hip_l", "shin_l": "kn_l",
            "thigh_r": "hip_r", "shin_r": "kn_r"}

def pose(base=None, **kw):
    p = {"root": [0.0, 0.0, 0.0, 22.0, 0.0, 0.0], "air": None}
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
    dx, lift, lean, twist, roll, dz = p["root"]
    r_root = mmul(rot_y(twist), mmul(rot_z(lean), rot_x(roll)))
    res = {}
    jr = lambda j: mmul(rot_y(p[j][1]), mmul(rot_x(p[j][0]), rot_z(p[j][2])))
    res["pelvis"] = (mmul(r_root, jr("pelvis")), [dx, 0.0, dz])
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
    root=(0, 0, 0, 24, 0, 0),
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

    # crouch: low behind the guard, for as long as down is held
    cr = pose(s, torso=(0, 4, -22), head=(0, -4, 16), sh_l=(6, 0, 70), el_l=(0, 0, 118),
              sh_r=(-6, 0, 62), el_r=(0, 0, 122), hip_l=(6, 0, 92), kn_l=(0, 0, -128),
              hip_r=(-6, 0, 58), kn_r=(0, 0, -132))
    A["crouch"] = (seq([s, cr], [2]), 2, "hold")
    A["cblock"] = ([pose(cr, root=(-6, 0, 0, 24, 0, 0), torso=(0, 4, -14)), cr, cr], 2, "once")
    # low punch: the lead hand, from the crouch
    lp = pose(cr, root=(6, 0, 0, 10, 0, 0), torso=(0, -14, -26), head=(0, 10, 18),
              sh_l=(0, 0, 84), el_l=(0, 0, 6))
    A["lowp"] = (seq([cr, lp, lp, cr], [2, 1, 2]), 2, "once")
    # sweep: the rear leg along the floor
    sw = pose(cr, root=(4, 0, 0, -8, 0, 0), torso=(0, 10, -6), head=(0, -10, 8),
              hip_r=(-10, 0, 96), kn_r=(0, 0, -4), hip_l=(6, 0, 100), kn_l=(0, 0, -140),
              sh_r=(-20, 0, -30), el_r=(0, 0, 40), sh_l=(0, 0, 40), el_l=(0, 0, 100))
    A["sweep"] = (seq([cr, sw, sw, cr], [3, 1, 3]), 2, "once")
    # jump: 3 steps on the ground (a second tap of up turns them into a
    # sidestep), 5 in the air, 2 landing. The air attacks keep these heights.
    s0 = pose(s, air=0)
    ja = pose(s0, torso=(0, 4, -18), hip_l=(4, 0, 52), kn_l=(0, 0, -74), hip_r=(-4, 0, 12), kn_r=(0, 0, -72),
              sh_l=(0, 0, 30), el_l=(0, 0, 60), sh_r=(-8, 0, -10), el_r=(0, 0, 70))
    ju = pose(s0, torso=(0, 4, -4), sh_l=(0, 0, 90), el_l=(0, 0, 50), sh_r=(-8, 0, 70), el_r=(0, 0, 60),
              hip_l=(4, 0, 30), kn_l=(0, 0, -50), hip_r=(-4, 0, 10), kn_r=(0, 0, -40))
    jt = pose(s0, torso=(0, 4, -12), sh_l=(0, 0, 70), el_l=(0, 0, 80), sh_r=(-8, 0, 40), el_r=(0, 0, 100),
              hip_l=(4, 0, 74), kn_l=(0, 0, -104), hip_r=(-4, 0, 54), kn_r=(0, 0, -100))
    jd = pose(s0, torso=(0, 4, -8), sh_l=(0, 0, 60), el_l=(0, 0, 70), sh_r=(-8, 0, 30), el_r=(0, 0, 90),
              hip_l=(4, 0, 34), kn_l=(0, 0, -44), hip_r=(-4, 0, 6), kn_r=(0, 0, -30))
    heights = [26, 50, 60, 50, 26]
    def arc(mid):
        """mid: the 5 poses in the air"""
        return ([s0, lerp(s0, ja, 0.6), ja] + [pose(m, air=h) for m, h in zip(mid, heights)] +
                [ja, lerp(ja, s0, 0.5)])
    A["jump"] = (arc([ju, jt, jt, jt, jd]), 2, "once")
    # flying kick: the rear leg out and down
    jk = pose(jt, torso=(0, 4, 16), head=(0, -6, -10), hip_r=(-4, 0, 72), kn_r=(0, 0, -4),
              hip_l=(4, 0, 64), kn_l=(0, 0, -114), sh_r=(-16, 0, -20), el_r=(0, 0, 50))
    A["jkick"] = (arc([ju, lerp(jt, jk, 0.6), jk, jk, lerp(jk, jd, 0.5)]), 2, "once")
    # the punch from above: the rear fist straight down at the head
    jp = pose(jt, torso=(0, -16, -24), head=(0, 12, 20), sh_r=(-4, 0, 64), el_r=(0, 0, 6),
              sh_l=(0, 0, 30), el_l=(0, 0, 110))
    A["jpunch"] = (arc([ju, lerp(jt, jp, 0.6), jp, jp, lerp(jp, jd, 0.5)]), 2, "once")
    # sidestep, to the fighter's left and to its right: out and back while
    # the ring turns under the two
    def side(d):
        a, b = ("hip_l", "hip_r") if d > 0 else ("hip_r", "hip_l")
        s1 = pose(s, root=(0, 0, 0, 24, 0, 16 * d), torso=(6 * d, 6, -12))
        s1[a][0] -= 24 * d
        s1[b][0] -= 6 * d
        s2 = pose(s, root=(0, 0, 0, 24, 0, 30 * d), torso=(-4 * d, 6, -10))
        s2[a][0] -= 8 * d
        s2[b][0] += 14 * d
        return seq([s, s1, s2, s1, s], [1, 1, 1, 1])
    A["step_l"] = (side(1), 2, "once")
    A["step_r"] = (side(-1), 2, "once")
    return A

# The moves the game logic knows, in the order of their numbers: animation,
# the step whose first tick hits, reach, damage, height.
#   high   goes over a crouch; a standing guard stops it
#   mid    either guard stops it
#   low    misses a fighter in the air; only the crouching guard stops it
#   over   (from the air) only the standing guard stops it
LEVELS = {"high": 0, "mid": 1, "low": 2, "over": 3}
MOVES = [("punch", "punch", 3, 86, 9, "high"), ("kick", "kick", 4, 102, 14, "mid"),
         ("lowp", "lowp", 2, 82, 6, "low"), ("sweep", "sweep", 3, 104, 12, "low"),
         ("jkick", "jkick", 6, 104, 16, "over"), ("jpunch", "jpunch", 6, 88, 12, "over")]
ANIM_ORDER = ["idle", "walk_f", "walk_b", "punch", "kick", "guard", "blockhit", "hit", "ko", "win",
              "crouch", "cblock", "lowp", "sweep", "jump", "jkick", "jpunch", "step_l", "step_r"]
# what an animation means to an attack that lands on it: 1 crouching, 2 the
# standing guard, 4 the crouching guard
ANIM_FLAGS = {"guard": 2, "blockhit": 2, "crouch": 1 | 4, "cblock": 1 | 4, "lowp": 1, "sweep": 1}
JUMP_AIR0, JUMP_AIR1 = 3, 7        # the steps of a jump that are in the air
REC = 24                           # bytes per part: 9 matrix words, 3 translation words
POSE_BYTES = REC * NPARTS

# ------------------------------------------------------------------ the ring
RING_TILES = 4          # tiles along each side of the ring's top

def build_ring():
    """a square platform: RING_TILES x RING_TILES tiles on top, a skirt on
    each side"""
    t = RING_TILES
    xs = [-RING + 2.0 * RING * i / t for i in range(t + 1)]
    verts = [[x, 0.0, z] for z in xs for x in xs]
    faces, normals, cols = [], [], []
    def add(f, n, col):
        p = [verts[k] for k in f]
        if dot(cross(vsub(p[1], p[0]), vsub(p[2], p[0])), n) < 0:
            f = [f[0], f[3], f[2], f[1]]
        faces.append(f); normals.append(n); cols.append(col)
    for j in range(t):
        for i in range(t):
            a = j * (t + 1) + i
            add([a, a + 1, a + t + 2, a + t + 1], [0.0, 1.0, 0.0], R("tile_a") if (i + j) % 2 == 0 else R("tile_b"))
    c00, c10, c01, c11 = 0, t, t * (t + 1), (t + 1) * (t + 1) - 1      # the top's corners
    b = len(verts)
    verts += [[-RING, -RING_H, -RING], [RING, -RING_H, -RING], [RING, -RING_H, RING], [-RING, -RING_H, RING]]
    add([c00, c10, b + 1, b], [0.0, 0.0, -1.0], R("skirt"))
    add([c10, c11, b + 2, b + 1], [1.0, 0.0, 0.0], R("skirt"))
    add([c11, c01, b + 3, b + 2], [0.0, 0.0, 1.0], R("skirt"))
    add([c01, c00, b, b + 3], [-1.0, 0.0, 0.0], R("skirt"))
    return verts, faces, normals, cols

# ------------------------------------------------------------------ output
def record(rot, t):
    return [q14(rot[i][j]) for i in range(3) for j in range(3)] + [s16(t[0]), s16(t[1]), s16(t[2])]

def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)

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
    assert POSES_BANK * POSE_BYTES <= 16384 and len(poses) <= 2 * POSES_BANK, len(poses)

    # ---- vertex and face streams: fighter 0, fighter 1, the ring (the
    # highest, so a RUN of the fighters' vertices leaves it alone). The
    # faces: the ring's first, so a RUN of NFACE_RING faces draws only it.
    vfight, vintro, ranges = [], [], []     # ranges[slot][part] = (first, end)
    fighter_faces = []
    marks = [-MARK_X, MARK_X]
    for slot, ch in enumerate(chars):
        sol = solve(ch, STANCE)
        rr, ff = [], []
        for part in PARTS:
            v, f, n, c = ch["parts"][part]
            first = len(vfight)
            vfight += v
            rot, org = sol[part]
            for p in v:                      # the same vertex in the world, in the stance
                wv = mvec(FACING[slot], vadd(mvec(rot, p), org))
                vintro.append([wv[0] + marks[slot], wv[1], wv[2]])
            rr.append((first, len(vfight)))
            rest = mmul(C0, mmul(FACING[slot], rot))     # slot 0 looks right, slot 1 left
            for fi, ni, ci in zip(f, n, c):
                ff.append(([first + i for i in fi], mvec(rest, ni), ci))
        ranges.append(rr)
        fighter_faces.append(ff)
    nv_fight = len(vfight)
    rv, rf, rn, rc = build_ring()
    vfight += rv
    vintro += rv
    nvert = len(vfight)
    ring_faces = [([nv_fight + i for i in f], mvec(C0, n), c) for f, n, c in zip(rf, rn, rc)]
    all_faces = ring_faces + fighter_faces[0] + fighter_faces[1]
    assert nvert <= 1023 and len(all_faces) <= 1023, (nvert, len(all_faces))   # geo3d v2.0
    assert max(b - a for rr in ranges for a, b in rr) <= 255           # NVERT of a part: one byte

    pack_v = lambda vs: b"".join(struct.pack("<3h", s16(x), s16(y), s16(z)) for x, y, z in vs)
    vbin = pack_v(vfight)
    # geo3d v2.0's extended face stream: I0..I3 (low bytes), their high bits
    # (2 each, I0 in bits 1-0), NX NY NZ, BASE: 12 bytes
    fbin = b""
    for idx, n, c in all_faces:
        hi = sum((i >> 8) << (2 * k) for k, i in enumerate(idx))
        fbin += bytes(i & 0xFF for i in idx) + bytes([hi]) + \
            struct.pack("<3h", q14(n[0]), q14(n[1]), q14(n[2])) + bytes([c])
    assert len(vbin) + len(fbin) <= 16384, len(vbin) + len(fbin)       # one bank: MODEL_BANK
    with open(os.path.join(OUT, "models.bin"), "wb") as f:
        f.write(vbin + fbin)
    with open(os.path.join(OUT, "vtx_intro.bin"), "wb") as f:
        f.write(pack_v(vintro))

    # ---- the palette: 256 x (R, G, B), 5 bits each
    pal = [(0, 0, 0)] * 256
    for k, rgb in FIXED.items():
        pal[k] = rgb
    for name, basei in RAMPS.items():
        r, g, b = RAMP_RGB[name]
        for t in range(7):
            s = 0.30 + 0.70 * t / 6.0
            pal[basei + t] = (int(round(r * s)), int(round(g * s)), int(round(b * s)))
    with open(os.path.join(OUT, "palette.bin"), "wb") as f:
        f.write(bytes(v for rgb in pal for v in rgb))

    # ---- pose records: two files (two banks of POSES_BANK poses) per
    # character and facing.
    # The fighter stands at x = 0 here; the Z80 adds x * KVEC.
    sols = []
    for ci, ch in enumerate(chars):
        data = [b"", b""]
        chrec = []
        for p in poses:
            sol = solve(ch, p)
            both = []
            for f in (0, 1):
                recs = []
                for part in PARTS:
                    rot, org = sol[part]
                    rec = record(mmul(C0, mmul(FACING[f], rot)), mvec(C0, vsub(mvec(FACING[f], org), CAM0)))
                    recs.append(rec)
                    data[f] += struct.pack("<12h", *rec)
                both.append(recs)
            chrec.append(both)
        for f in (0, 1):
            for half in (0, 1):
                with open(os.path.join(OUT, "pose_%d_%d_%d.bin" % (ci, f, half)), "wb") as fo:
                    fo.write(data[f][half * POSES_BANK * POSE_BYTES:(half + 1) * POSES_BANK * POSE_BYTES])
        sols.append(chrec)

    # ---- the ring in a fight: the camera's own matrix
    ring_rec = record(C0, mvec(C0, [-CAM0[0], -CAM0[1], -CAM0[2]]))

    # ---- the opening shot: one turn around the ring, closing in and coming
    # down, ending exactly on the fight camera. Per frame: the camera record
    # (the vertices are in the world) and the light register.
    orbit, orbit_bin = [], b""
    for i in range(ORBIT_N):
        t = (i + 1) / ORBIT_N
        yaw = CAM_YAW - 360.0 * (1.0 - smooth(t))
        z = smooth((t - 0.30) / 0.70)
        c, pos = camera(yaw, ORBIT_PITCH + (CAM_PITCH - ORBIT_PITCH) * z, ORBIT_DIST + (CAM_DIST - ORBIT_DIST) * z)
        rec = record(c, mvec(c, [-pos[0], -pos[1], -pos[2]]))
        lg = light(c)
        orbit.append((rec, lg))
        orbit_bin += struct.pack("<15h", *(rec + lg))
    assert orbit[-1][0] == ring_rec, "the opening shot must end on the fight camera"
    with open(os.path.join(OUT, "orbit.bin"), "wb") as f:
        f.write(orbit_bin)

    # ---- the ring under a turned axis: its matrix and the light that goes
    # with it, per step of the turn (the translation is always ring_rec's:
    # the ring turns about its own centre)
    ring_tab = b""
    for a in range(AXIS_N):
        m = mmul(C0, rot_y(360.0 * a / AXIS_N))
        ring_tab += struct.pack("<12h", *([q14(m[i][j]) for i in range(3) for j in range(3)] + light(m)))
    with open(os.path.join(OUT, "ring_tab.bin"), "wb") as f:
        f.write(ring_tab)

    lr = light(C0)                      # (tools/preview.py)
    l0 = [q14(v) for v in LIGHT0]
    with open(os.path.join(OUT, "inc", "const.asm"), "w") as f:
        w = lambda s: f.write(s + "\n")
        w("; generated by tools/gen_fighter.py")
        w("ROM_BANKS:   equ 16")
        w("POSE_BANK0:  equ 2               ; + 2 * (2 * character + facing) + (pose >= POSES_BANK)")
        w("MODEL_BANK:  equ 10              ; the fight's vertices, then the faces")
        for k, v in (("G3_W", G3_W), ("G3_H", G3_H), ("G3_F", G3_F), ("G3_CX", G3_CX), ("G3_CY", G3_CY),
                     ("G3_ZNEAR", G3_ZNEAR), ("VIEW_Y0", VIEW_Y0), ("NVERT_ALL", nvert), ("NVERT_FIGHT", nv_fight),
                     ("NVERT_RING", nvert - nv_fight), ("NFACE_ALL", len(all_faces)),
                     ("NFACE_RING", len(ring_faces)), ("NFACE_FIGHT", len(all_faces) - len(ring_faces)),
                     ("NPARTS", NPARTS),
                     ("POSE_REC", REC), ("POSE_BYTES", POSE_BYTES), ("VTX_BYTES", len(vbin)),
                     ("FACE_BYTES", len(fbin)), ("ORBIT_N", ORBIT_N), ("ORBIT_REC", 30),
                     ("KVEC_X", q14(KVEC[0])), ("KVEC_Y", q14(KVEC[1])), ("KVEC_Z", q14(KVEC[2])),
                     ("LIGHT_X", l0[0]), ("LIGHT_Y", l0[1]), ("LIGHT_Z", l0[2]),
                     ("WALK_X", WALK_X), ("MARK_X", MARK_X), ("MIN_SEP", MIN_SEP), ("CAM_MAX", CAM_MAX),
                     ("POSES_BANK", POSES_BANK), ("AXIS_N", AXIS_N), ("STEP_TURN", STEP_TURN),
                     ("JUMP_AIR0", JUMP_AIR0), ("JUMP_AIR1", JUMP_AIR1),
                     ("COL_BLACK", COL_BLACK), ("COL_WHITE", COL_WHITE), ("COL_GROUND", COL_GROUND),
                     ("COL_YELLOW", COL_YELLOW), ("COL_RED", COL_RED), ("COL_BARBG", COL_BARBG),
                     ("COL_FRAME", COL_FRAME), ("COL_GREEN", COL_GREEN), ("COL_ORANGE", COL_ORANGE)):
            w("%s:%s equ %d" % (k, " " * max(1, 12 - len(k)), v))
        for i, name in enumerate(ANIM_ORDER):
            w("AN_%s:%s equ %d" % (name.upper(), " " * (9 - len(name)), i))
        for i, mv in enumerate(MOVES):
            w("MV_%s:%s equ %d" % (mv[0].upper(), " " * (9 - len(mv[0])), i))
        for name, v in LEVELS.items():
            w("LV_%s:%s equ %d" % (name.upper(), " " * (9 - len(name)), v))

    with open(os.path.join(OUT, "inc", "tables.asm"), "w") as f:
        w = lambda s: f.write(s + "\n")
        w("; generated by tools/gen_fighter.py")
        w("; each part's vertices, per slot: the first one (a word), how many (a byte)")
        for slot in (0, 1):
            w("part_v_%d:" % slot)
            for i in range(NPARTS):
                a, b = ranges[slot][i]
                w("        dw %d\n        db %d          ; %s" % (a, b - a, PARTS[i]))
        w("ring_t0:                        ; the ring's translation under the fight camera")
        w("        dw " + ", ".join(str(v) for v in ring_rec[9:]))
        w("; moves: animation, hit step, reach, damage, height")
        w("move_tab:")
        for name, anim, step, reach, dmg, lv in MOVES:
            w("        db %d, %d, %d, %d, %d      ; %s" % (ANIM_ORDER.index(anim), step, reach, dmg, LEVELS[lv], name))
        w("; per animation: 1 crouching, 2 the standing guard, 4 the crouching guard")
        w("anim_fl:")
        w("        db " + ", ".join(str(ANIM_FLAGS.get(n, 0)) for n in ANIM_ORDER))
        w("; animations: first pose, steps, ticks per step, mode (0 loop, 1 once, 2 hold, 3 loop the last 4)")
        w("anim_tab:")
        modes = {"loop": 0, "once": 1, "hold": 2, "loopend": 3}
        for name in ANIM_ORDER:
            first, n, ticks, mode = anim_steps[name]
            w("        db %d, %d, %d, %d      ; %s" % (first, n, ticks, modes[mode], name))

    # ---- everything the preview needs
    gen = {"view": {"W": G3_W, "H": G3_H, "F": G3_F, "CX": G3_CX, "CY": G3_CY, "ZNEAR": G3_ZNEAR, "Y0": VIEW_Y0},
           "light0": l0, "light_ring": lr, "kvec": [q14(v) for v in KVEC],
           "poses": len(poses), "anims": anim_steps, "parts": PARTS,
           "nvert": nvert, "nv_fight": nv_fight, "nface": len(all_faces), "nface_ring": len(ring_faces),
           "vfight": [[s16(c) for c in v] for v in vfight], "vintro": [[s16(c) for c in v] for v in vintro],
           "faces": [[idx, [q14(x) for x in n], c] for idx, n, c in all_faces],
           "ranges": ranges, "ring_rec": ring_rec, "pose_recs": sols, "orbit": orbit,
           "palette": pal, "ground": COL_GROUND}
    with open(os.path.join(OUT, "gen.json"), "w") as f:
        json.dump(gen, f)
    per = [sum(len(ch["parts"][p][0]) for p in PARTS) for ch in chars], [sum(len(ch["parts"][p][1]) for p in PARTS) for ch in chars]
    print("gen_fighter: %d vertices, %d faces (fighters %s vertices, %s faces; ring %d, %d), %d poses, %d orbit frames" %
          (nvert, len(all_faces), per[0], per[1], len(rv), len(ring_faces), len(poses), ORBIT_N))

if __name__ == "__main__":
    main()
