"""OPS Mobile phone masts (cell towers). Generic look, no real operator branding.
  opslabs_mast_lattice          25 m square self-supporting lattice tower (dark green steel), headframe with
                                three sector panel antennas, RRUs, a microwave dish, caged ladder, cable ladder
  opslabs_mast_lattice_compound ground kit for it: GRP equipment cabin, cable gantry, meter cabinet, timber
                                post-and-rail fence with a pedestrian gate, gravel pad
  opslabs_mast_5g               17.5 m roadside 5G monopole with shroud, root cabinet, equipment cabinet and
                                meter pillar on a concrete plinth
blender -b --python build_masts.py -- <out_dir>
Origin = centre of the mast foot at ground level (z = 0), mast up +Z, front (doors, signs) facing -Y.
The compound shares the lattice tower's origin. Masts get a simpler MEDIUM LOD (high -> 150 m, med -> 600 m)
and a simplified hand-built collision (not the render mesh).
Antenna centres: lattice 22.0 m (sectors at headings 0 / 120 / 240, i.e. +Y and the two front diagonals),
5G 16.65 m (shroud panel section).
"""
import math
import os
import sys

import bmesh
import bpy
import mathutils

OUT = sys.argv[sys.argv.index('--') + 1]
TEX = os.path.join(OUT, 'tex')
os.makedirs(TEX, exist_ok=True)
HERE = os.path.dirname(os.path.abspath(__file__))
addon = 'bl_ext.user_default.sollumz'
import addon_utils  # noqa: E402
addon_utils.enable(addon, default_set=True)
from importlib import import_module  # noqa: E402
sz_mats = import_module(addon + '.ydr.shader_materials')
sz_col = import_module(addon + '.ybn.collision_materials')
sz_props = import_module(addon + '.sollumz_properties')
exec(open(os.path.join(HERE, 'canvas_lib.py')).read())

FONT = {
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], 'P': ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
    'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'], 'M': ['10001', '11011', '10101', '10101', '10001', '10001', '10001'],
    'B': ['11110', '10001', '10001', '11110', '10001', '10001', '11110'], 'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'],
    'L': ['10000', '10000', '10000', '10000', '10000', '10000', '11111'], 'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], 'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'],
    '0': ['01110', '10001', '10011', '10101', '11001', '10001', '01110'], '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
    '2': ['01110', '10001', '00001', '00010', '00100', '01000', '11111'], '3': ['11110', '00001', '00001', '01110', '00001', '00001', '11110'],
    '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'], '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
    '-': ['00000', '00000', '00000', '11111', '00000', '00000', '00000'], ' ': ['00000'] * 7,
}


def text(c, s, x, y, px, color):
    for ch in s:
        g = FONT.get(ch)
        if g:
            for ry, row in enumerate(g):
                for rx, bit in enumerate(row):
                    if bit == '1':
                        c.rect(x + rx * px, y + ry * px, x + (rx + 1) * px, y + (ry + 1) * px, color)
        x += 6 * px


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


def warn(c, x, y, s):
    """small yellow warning triangle sticker (black border, black '!' mark), top-left corner at x, y"""
    c.rect(x, y, x + s, y + s, (236, 196, 24))
    for k in range(s):
        half = k / 2
        cx = x + s / 2
        c.rect(cx - half - 1, y + k, cx - half + 1, y + k + 1, (20, 20, 20))
        c.rect(cx + half - 1, y + k, cx + half + 1, y + k + 1, (20, 20, 20))
    c.rect(x + 1, y + s - 2, x + s - 1, y + s, (20, 20, 20))
    c.rect(x + s / 2 - 1, y + s * 0.35, x + s / 2 + 1, y + s * 0.7, (20, 20, 20))
    c.rect(x + s / 2 - 1, y + s * 0.77, x + s / 2 + 1, y + s * 0.85, (20, 20, 20))


import random  # noqa: E402
rnd = random.Random(5)

# ---------------------------------------------------------------- textures
GREEN = (44, 64, 50)
c = Canvas(64, 128, GREEN)                                                                # weathered green steel
for _ in range(40):
    x, y = rnd.randrange(64), rnd.randrange(128)
    c.rect(x, y, x + rnd.randrange(1, 4), y + rnd.randrange(2, 8), (70, 62, 46), 0.5)     # rust / dust streaks
for _ in range(30):
    x, y = rnd.randrange(64), rnd.randrange(128)
    c.rect(x, y, x + 2, y + rnd.randrange(3, 12), (64, 84, 70), 0.5)                      # chalky paint
c.noise(6); save(c, 'opslabs_mst_green')
c = Canvas(64, 64, (150, 154, 158)); c.noise(10); save(c, 'opslabs_mst_galv')
c = Canvas(64, 64, (128, 128, 124)); c.noise(14); save(c, 'opslabs_mst_concrete')
c = Canvas(64, 64, (232, 233, 230)); c.noise(3); save(c, 'opslabs_mst_white')
c = Canvas(64, 64, (140, 143, 146)); c.noise(4); save(c, 'opslabs_mst_rru')
c = Canvas(64, 64, (22, 22, 24)); c.noise(3); save(c, 'opslabs_mst_black')
c = Canvas(64, 64, (100, 104, 106))                                                       # steel grating
for k in range(0, 64, 8):
    c.rect(k, 0, k + 2, 64, (150, 154, 156)); c.rect(0, k, 64, k + 1, (140, 144, 146))
c.noise(4); save(c, 'opslabs_mst_grating')
c = Canvas(64, 256, (234, 235, 232))                                                      # sector antenna radome face
c.rect(0, 0, 64, 6, (200, 202, 200)); c.rect(0, 250, 64, 256, (200, 202, 200))
c.rect(0, 0, 3, 256, (214, 216, 214)); c.rect(61, 0, 64, 256, (214, 216, 214))
c.rect(20, 238, 44, 244, (180, 182, 182))
c.noise(2); save(c, 'opslabs_mst_antface')
# GRP cabin sides: dark green, moulded vertical panel ribs
c = Canvas(128, 128, (40, 60, 46))
for x in range(0, 128, 32):
    c.rect(x, 0, x + 3, 128, (30, 46, 36)); c.rect(x + 3, 0, x + 5, 128, (52, 74, 58))
c.rect(0, 0, 128, 4, (32, 50, 38))
c.noise(4); save(c, 'opslabs_mst_grp')
# GRP cabin front (-Y face, 2.0 x 2.25 m): central door with handle, OPS Mobile site sign, warning sticker
c = Canvas(256, 288, (40, 60, 46))
c.rect(68, 32, 188, 288, (30, 46, 36)); c.rect(72, 36, 184, 288, (44, 66, 50))           # door 0.9 x 2.0
for y in range(70, 270, 60):
    c.rect(72, y, 184, y + 2, (36, 54, 42))
c.rect(166, 150, 176, 182, (170, 172, 170)); c.rect(160, 160, 178, 166, (190, 192, 190))  # handle / lock
c.rect(88, 66, 168, 112, (240, 240, 238)); c.rect(88, 66, 168, 80, (0, 120, 190))         # site sign
text(c, 'OPS', 102, 69, 2, (255, 255, 255)); text(c, 'MOBILE', 92, 86, 2, (0, 90, 150))
text(c, '7041', 104, 100, 1, (40, 40, 40))
warn(c, 116, 120, 22)
c.rect(0, 0, 256, 6, (32, 50, 38))
c.noise(3); save(c, 'opslabs_mst_cabinfront')
c = Canvas(64, 256, (120, 98, 72))                                                        # weathered timber
for x in range(0, 64, 5):
    c.rect(x, 0, x + 1, 256, (100, 80, 58), 0.6)
for _ in range(20):
    x, y = rnd.randrange(64), rnd.randrange(256)
    c.rect(x, y, x + 3, y + 3, (80, 64, 46), 0.7)
c.noise(8); save(c, 'opslabs_mst_timber')
c = Canvas(128, 128, (126, 124, 118)); c.noise(30)                                        # gravel
for _ in range(500):
    x, y = rnd.randrange(128), rnd.randrange(128)
    g = rnd.randrange(80, 190)
    c.rect(x, y, x + 2, y + 2, (g, g - 4, g - 10))
save(c, 'opslabs_mst_gravel')
c = Canvas(128, 192, (150, 154, 152))                                                     # meter cabinet front
c.rect(6, 6, 122, 186, (122, 126, 124)); c.rect(9, 9, 119, 183, (156, 160, 158))
c.rect(100, 90, 110, 110, (60, 60, 60)); warn(c, 50, 30, 26); c.noise(3); save(c, 'opslabs_mst_meterfront')
GREY = (204, 208, 204)                                                                    # RAL 7035 light grey
c = Canvas(64, 64, GREY); c.noise(3); save(c, 'opslabs_mst_grey')
c = Canvas(64, 64, (86, 90, 92)); c.noise(3); save(c, 'opslabs_mst_vent')
c = Canvas(64, 256, GREY)                                                                 # shroud panel: seams
c.rect(0, 0, 3, 256, (170, 174, 172)); c.rect(61, 0, 64, 256, (180, 184, 182))
c.rect(0, 0, 64, 4, (176, 180, 178)); c.rect(0, 252, 64, 256, (176, 180, 178))
c.noise(2); save(c, 'opslabs_mst_shroud')
# root cabinet front (1.4 x 1.3 m): two doors, handles, stickers
c = Canvas(256, 240, GREY)
for x0 in (8, 130):
    c.rect(x0, 8, x0 + 118, 232, (176, 180, 177)); c.rect(x0 + 3, 11, x0 + 115, 229, (210, 214, 210))
c.rect(110, 100, 118, 140, (110, 112, 112)); c.rect(138, 100, 146, 140, (110, 112, 112))
warn(c, 30, 30, 24); warn(c, 156, 30, 24)
c.rect(30, 64, 90, 84, (250, 250, 250)); c.rect(32, 66, 88, 70, (0, 120, 190))
c.noise(2); save(c, 'opslabs_mst_rootfront')
# equipment cabinet front (1.6 x 1.48 m): perforated doors
c = Canvas(256, 240, GREY)
for x0 in (8, 132):
    c.rect(x0, 8, x0 + 116, 232, (172, 176, 173)); c.rect(x0 + 3, 11, x0 + 113, 229, (208, 212, 208))
    for yy in range(40, 220, 7):
        for xx in range(x0 + 12, x0 + 106, 7):
            c.rect(xx, yy, xx + 3, yy + 3, (110, 114, 116))
c.rect(118, 110, 124, 140, (100, 102, 102)); c.rect(134, 110, 140, 140, (100, 102, 102))
warn(c, 24, 14, 20); warn(c, 210, 14, 20)
c.noise(2); save(c, 'opslabs_mst_equipfront')
c = Canvas(128, 128, GREY)                                                                # equipment cabinet side: vents
for yy in range(16, 112, 6):
    c.rect(20, yy, 108, yy + 3, (110, 114, 116))
c.noise(2); save(c, 'opslabs_mst_equipside')
c = Canvas(64, 192, GREY)                                                                 # meter pillar front
c.rect(4, 4, 60, 188, (176, 180, 177)); c.rect(7, 7, 57, 185, (210, 214, 210))
c.rect(16, 40, 48, 70, (60, 70, 76)); warn(c, 22, 100, 20); c.rect(50, 110, 54, 130, (110, 112, 112))
c.noise(2); save(c, 'opslabs_mst_pillarfront')
c = Canvas(64, 128, GREY)                                                                 # pole cable access door
c.rect(2, 2, 62, 126, (150, 154, 152)); c.rect(5, 5, 59, 123, (200, 204, 200))
warn(c, 20, 20, 24); c.rect(28, 90, 36, 100, (90, 92, 92))
c.noise(2); save(c, 'opslabs_mst_poledoor')

MATS = {}


def mat(name, shader='default.sps'):
    key = (name, shader)
    if key in MATS:
        return MATS[key]
    m = sz_mats.create_shader(shader)
    m.name = name
    img = bpy.data.images.load(os.path.join(TEX, name + '.dds'), check_existing=True)
    img.name = name
    for node in m.node_tree.nodes:
        if isinstance(node, bpy.types.ShaderNodeTexImage) and node.name == 'DiffuseSampler':
            node.image = img
            node.texture_properties.embedded = True
    MATS[key] = m
    return m


for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def new_bm():
    bm = bmesh.new()
    return bm, bm.loops.layers.uv.new('UVMap 0')


def to_mesh(name, bm, mats):
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    col = me.color_attributes.new('Color 1', 'BYTE_COLOR', 'CORNER')
    for d in col.data:
        d.color = (1, 1, 1, 1)
    return me


def finish(name, bm, mats):
    obj = bpy.data.objects.new(name, to_mesh(name, bm, mats))
    bpy.context.scene.collection.objects.link(obj)
    return obj


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, back=None, side=None, tf=None):
    F = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    over = {'front': front, 'back': back, 'left': side, 'right': side}
    for k, vs in F.items():
        if tf:
            vs = [tf(v) for v in vs]
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = over[k] if over.get(k) is not None else mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


def orient(cx, cy, fx, fy):
    """local -> world for a box whose local -Y face (front) points along (fx, fy); local x = viewer's right"""
    rx, ry = -fy, fx

    def tf(v):
        x, y, z = v
        return (cx + rx * x - fx * y, cy + ry * x - fy * y, z)
    return tf


def cyl(bm, uv, p0, p1, r0, r1=None, sides=12, mi=0, vrep=1.0, phase=0.0, caps=True, smooth=True):
    r1 = r0 if r1 is None else r1
    a, b = mathutils.Vector(p0), mathutils.Vector(p1)
    d = (b - a).normalized()
    t = mathutils.Vector((1, 0, 0)) if abs(d.x) < 0.9 else mathutils.Vector((0, 1, 0))
    u = d.cross(t).normalized()
    w = d.cross(u).normalized()
    angs = [phase + 2 * math.pi * i / sides for i in range(sides)]
    rings = [[bm.verts.new(c + (u * math.cos(an) + w * math.sin(an)) * r) for an in angs] for c, r in ((a, r0), (b, r1))]
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
        f.material_index = mi
        f.smooth = smooth
        for loop, uvv in zip(f.loops, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, vrep), (i / sides, vrep))):
            loop[uv].uv = uvv
    if caps:
        for k, ring in enumerate(rings):
            if (r0 if k == 0 else r1) > 0.0005:
                f = bm.faces.new(ring if k else list(reversed(ring)))
                f.material_index = mi
                for loop in f.loops:
                    loop[uv].uv = (0.5, 0.5)


def bar(bm, uv, p0, p1, w, mi=0, caps=False):
    """square-section member (4-sided prism)"""
    cyl(bm, uv, p0, p1, w * 0.7071, sides=4, mi=mi, phase=math.pi / 4, caps=caps, smooth=False, vrep=4)


def path(bm, uv, pts, r, sides=5, mi=0):
    for p, q in zip(pts, pts[1:]):
        cyl(bm, uv, p, q, r, sides=sides, mi=mi, caps=False)


def prism(bm, uv, pts, z0, z1, mi=0, side_mi=None):
    """extrude a CCW 2D outline from z0 to z1 (each side face gets the full 0..1 UV)"""
    bot = [bm.verts.new((x, y, z0)) for x, y in pts]
    top = [bm.verts.new((x, y, z1)) for x, y in pts]
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        f = bm.faces.new((bot[i], bot[j], top[j], top[i]))
        f.material_index = mi if side_mi is None else side_mi
        for loop, uvv in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = uvv
    for ring, rev in ((top, False), (bot, True)):
        f = bm.faces.new(list(reversed(ring)) if rev else ring)
        f.material_index = mi
        for loop in f.loops:
            loop[uv].uv = (loop.vert.co.x, loop.vert.co.y)


def chamfer_sq(h, c):
    """square of half-size h with corners cut by c, CCW"""
    return [(h, -h + c), (h, h - c), (h - c, h), (-h + c, h), (-h, h - c), (-h, -h + c), (-h + c, -h), (h - c, -h)]


models = []


def add(obj, lod, colmat=None, colmesh=None, med=None, lod_hi=None):
    models.append(dict(obj=obj, lod=lod, colmat=colmat, colmesh=colmesh, med=med, lod_hi=lod_hi))


def heading(h):
    """GTA heading (degrees, 0 = +Y, counter-clockwise) -> unit 2D vector"""
    r = math.radians(h)
    return (-math.sin(r), math.cos(r))


# ======================================================================= lattice tower
TOP, TAPER_Z, HB, HT = 25.0, 20.0, 1.2, 0.6
ANT_Z = 22.0                                                     # antenna centre height
SECTORS = (0, 120, 240)


def hw(z):
    return HB - (HB - HT) * min(max(z, 0.0), TAPER_Z) / TAPER_Z


def fpt(face, z, t, out=0.0):
    """point on tower face `face` (0 = -Y, 1 = +X, 2 = +Y, 3 = -X) at height z, t in [-1, 1] along it"""
    h = hw(z)
    hh = h + out
    return [(t * h, -hh, z), (hh, t * h, z), (-t * h, hh, z), (-hh, -t * h, z)][face]


FNORM = [(0, -1), (1, 0), (0, 1), (-1, 0)]
LEVELS = [0.3 + i * (TAPER_Z - 0.3) / 8 for i in range(9)] + [22.5, TOP]
FR = 1.05                                                        # headframe half size


def sector_pole(h):
    dx, dy = heading(h)
    s = FR / max(abs(dx), abs(dy))
    return dx * s, dy * s


L_MATS = lambda: [mat('opslabs_mst_green'), mat('opslabs_mst_galv'), mat('opslabs_mst_concrete'), mat('opslabs_mst_white'),  # noqa: E731
                  mat('opslabs_mst_rru'), mat('opslabs_mst_black'), mat('opslabs_mst_grating'), mat('opslabs_mst_antface')]


def build_lattice(detail):
    bm, uv = new_bm()
    LEG = 0.16 if detail else 0.18
    # foundation pads + base plates
    for sx in (-1, 1):
        for sy in (-1, 1):
            cx, cy = sx * HB, sy * HB
            box(bm, uv, cx - 0.45, cy - 0.45, -0.2, cx + 0.45, cy + 0.45, 0.3, mi=2)
            box(bm, uv, cx - 0.2, cy - 0.2, 0.3, cx + 0.2, cy + 0.2, 0.33, mi=0)
            if detail:
                for bx in (-0.14, 0.14):
                    for by in (-0.14, 0.14):
                        cyl(bm, uv, (cx + bx, cy + by, 0.33), (cx + bx, cy + by, 0.40), 0.018, sides=6, mi=1)
    # legs: L-angles (two flanges) in detail, square bars in the LOD
    for sx in (-1, 1):
        for sy in (-1, 1):
            pts = [(sx * hw(z), sy * hw(z), z) for z in (0.33, TAPER_Z, TOP)]
            for p, q in zip(pts, pts[1:]):
                if detail:
                    T = 0.018
                    # flange in the X-face plane and in the Y-face plane, on the outside corner
                    for ax in (0, 1):
                        # flange in the X-face plane (ax 0) or the Y-face plane (ax 1), on the outside corner
                        if ax == 0:
                            mid_a = (p[0] - sx * LEG / 2, p[1] - sy * T / 2, p[2]); mid_b = (q[0] - sx * LEG / 2, q[1] - sy * T / 2, q[2])
                        else:
                            mid_a = (p[0] - sx * T / 2, p[1] - sy * LEG / 2, p[2]); mid_b = (q[0] - sx * T / 2, q[1] - sy * LEG / 2, q[2])
                        w_ = LEG / 2
                        corners = []
                        for (mx, my, mz) in (mid_a, mid_b):
                            if ax == 0:
                                corners.append([(mx - w_, my - T / 2, mz), (mx + w_, my - T / 2, mz), (mx + w_, my + T / 2, mz), (mx - w_, my + T / 2, mz)])
                            else:
                                corners.append([(mx - T / 2, my - w_, mz), (mx + T / 2, my - w_, mz), (mx + T / 2, my + w_, mz), (mx - T / 2, my + w_, mz)])
                        bv = [bm.verts.new(v) for v in corners[0]]
                        tv = [bm.verts.new(v) for v in corners[1]]
                        for i in range(4):
                            j = (i + 1) % 4
                            f = bm.faces.new((bv[i], bv[j], tv[j], tv[i]))
                            f.material_index = 0
                            for loop, uvv in zip(f.loops, ((0, 0), (1, 0), (1, 6), (0, 6))):
                                loop[uv].uv = uvv
                        f = bm.faces.new(list(reversed(bv))); f.material_index = 0
                        f = bm.faces.new(tv); f.material_index = 0
                else:
                    inset = (-sx * LEG / 2, -sy * LEG / 2, 0)
                    bar(bm, uv, tuple(a + b for a, b in zip(p, inset)), tuple(a + b for a, b in zip(q, inset)), LEG, mi=0, caps=True)
    # horizontals + face bracing
    BW = 0.075 if detail else 0.09
    for face in range(4):
        for i, z in enumerate(LEVELS):
            bar(bm, uv, fpt(face, z, -1), fpt(face, z, 1), 0.085)
            if i + 1 >= len(LEVELS):
                continue
            z1 = LEVELS[i + 1]
            if i < 2:                                            # K / diamond bracing in the wide bottom panels
                zm = (z + z1) / 2
                for s in (-1, 1):
                    bar(bm, uv, fpt(face, zm, s), fpt(face, z, 0), BW)
                    bar(bm, uv, fpt(face, zm, s), fpt(face, z1, 0), BW)
                if detail:
                    bar(bm, uv, fpt(face, zm, -1), fpt(face, zm, 1), 0.05)
            else:                                                # X bracing
                bar(bm, uv, fpt(face, z, -1), fpt(face, z1, 1), BW)
                bar(bm, uv, fpt(face, z, 1), fpt(face, z1, -1), BW)
    # plan bracing at a few levels + top
    for z in (LEVELS[4], TAPER_Z, TOP):
        h = hw(z)
        bar(bm, uv, (-h, -h, z), (h, h, z), 0.07)
        bar(bm, uv, (-h, h, z), (h, -h, z), 0.07)
    # ---- caged climbing ladder (inside, climber on the -Y side), from the pad level to the top
    LX, LY = 0.15, 0.10
    for x in (LX - 0.2, LX + 0.2):
        bar(bm, uv, (x, LY, 0.3), (x, LY, TOP + 0.9), 0.05, mi=1)
    if detail:
        z = 0.6
        while z < TOP + 0.6:
            cyl(bm, uv, (LX - 0.2, LY, z), (LX + 0.2, LY, z), 0.013, sides=5, mi=1, caps=False)
            z += 0.3
        CC, CR = (LX, -0.2), 0.36
        arc = [math.radians(a) for a in range(40, -221, -26)]
        z = 2.6
        while z < TOP + 0.6:
            pts = [(CC[0] + CR * math.cos(a), CC[1] + CR * math.sin(a), z) for a in arc]
            pts = [(LX + 0.2, LY, z)] + pts + [(LX - 0.2, LY, z)]
            path(bm, uv, pts, 0.012, sides=4, mi=1)
            z += 0.9
        for a in (-10, -50, -90, -130, -170):
            ar = math.radians(a)
            x, y = CC[0] + CR * math.cos(ar), CC[1] + CR * math.sin(ar)
            bar(bm, uv, (x, y, 2.6), (x, y, z - 0.9), 0.03, mi=1)
        box(bm, uv, LX - 0.3, -0.62, 0.4, LX + 0.3, -0.6, 2.6, mi=1)              # lockable anti-climb door on the cage
        for a in (-30, -150):
            ar = math.radians(a)
            x, y = CC[0] + CR * math.cos(ar), CC[1] + CR * math.sin(ar)
            bar(bm, uv, (x, y, 0.4), (x, y, 2.6), 0.04, mi=1)
    # ---- cable ladder with black feeders, beside the climbing ladder (cabin side, -X)
    CX0, CX1 = -0.50, -0.22
    for x in (CX0, CX1):
        bar(bm, uv, (x, LY, 2.0), (x, LY, TAPER_Z), 0.05, mi=1)
    if detail:
        z = 2.2
        while z < TAPER_Z:
            bar(bm, uv, (CX0, LY, z), (CX1, LY, z), 0.03, mi=1)
            z += 0.4
        for k in range(6):
            x = CX0 + 0.04 + k * 0.04
            cyl(bm, uv, (x, LY + 0.04, 2.2), (x, LY + 0.04, TAPER_Z + 0.1), 0.014, sides=5, mi=5, caps=False, vrep=20)
    else:
        box(bm, uv, CX0, LY + 0.02, 2.2, CX1, LY + 0.07, TAPER_Z, mi=5)
    # ---- anti-climb guard: outward-sloping spikes round all four faces at ~3 m + a rest platform
    if detail:
        for face in range(4):
            nx, ny = FNORM[face]
            ends = []
            for k in range(13):
                t = -0.9 + k * 0.15
                p = fpt(face, 2.8, t)
                q = (p[0] + nx * 0.45, p[1] + ny * 0.45, 3.2)
                bar(bm, uv, p, q, 0.025, mi=1)
                ends.append(q)
            path(bm, uv, ends, 0.015, sides=4, mi=1)
            bar(bm, uv, fpt(face, 2.8, -1), fpt(face, 2.8, 1), 0.06, mi=1)
    h = hw(5.3) - 0.05
    box(bm, uv, -h, -h + 0.7, 5.28, h, h, 5.32, mi=6)                               # rest platform (grating)
    # ---- headframe: square frame (half FR) at the platform level and at the top of the antennas
    for z in (TAPER_Z, 23.0):
        cs = [(FR, FR), (-FR, FR), (-FR, -FR), (FR, -FR)]
        for (ax, ay), (bx, by) in zip(cs, cs[1:] + cs[:1]):
            bar(bm, uv, (ax, ay, z), (bx, by, z), 0.07, mi=0)
        for sx in (-1, 1):
            for sy in (-1, 1):
                bar(bm, uv, (sx * HT, sy * HT, z), (sx * FR, sy * FR, z), 0.08, mi=0)
    for sx in (-1, 1):
        for sy in (-1, 1):
            bar(bm, uv, (sx * FR, sy * FR, TAPER_Z), (sx * FR, sy * FR, 23.0), 0.06, mi=0)   # frame corner posts
            bar(bm, uv, (sx * hw(18.4), sy * hw(18.4), 18.4), (sx * FR, sy * FR, TAPER_Z), 0.06, mi=0)  # knee braces
    box(bm, uv, -FR, -FR, TAPER_Z - 0.02, FR, FR, TAPER_Z + 0.02, mi=6)              # platform grating
    if detail:
        cs = [(FR, FR), (-FR, FR), (-FR, -FR), (FR, -FR)]
        for (ax, ay), (bx, by) in zip(cs, cs[1:] + cs[:1]):
            bar(bm, uv, (ax, ay, TAPER_Z + 1.1), (bx, by, TAPER_Z + 1.1), 0.045, mi=1)  # handrail
            box(bm, uv, min(ax, bx) - 0.01, min(ay, by) - 0.01, TAPER_Z, max(ax, bx) + 0.01, max(ay, by) + 0.01, TAPER_Z + 0.15, mi=1)  # toe board
    # ---- sector antennas: pole on the frame, panel 1.4 m x 0.32 x 0.12 facing out, RRU behind (2 of 3)
    for k, hd in enumerate(SECTORS):
        px, py = sector_pole(hd)
        fx, fy = heading(hd)
        cyl(bm, uv, (px, py, TAPER_Z - 0.1), (px, py, 23.5), 0.045, sides=8 if detail else 6, mi=0)
        tf = orient(px + fx * 0.19, py + fy * 0.19, fx, fy)
        box(bm, uv, -0.16, -0.06, ANT_Z - 0.7, 0.16, 0.06, ANT_Z + 0.7, mi=3, front=7, tf=tf)
        if detail:
            for z in (ANT_Z - 0.5, ANT_Z + 0.5):
                box(bm, uv, -0.03, 0.06, z - 0.03, 0.03, 0.15, z + 0.03, mi=1, tf=tf)         # clamp brackets
            box(bm, uv, -0.1, -0.03, ANT_Z - 0.76, 0.1, 0.04, ANT_Z - 0.7, mi=1, tf=tf)       # connector base
            if k < 2:
                tr = orient(px - fx * 0.14, py - fy * 0.14, fx, fy)
                box(bm, uv, -0.15, -0.07, ANT_Z - 0.75, 0.15, 0.07, ANT_Z - 0.3, mi=4, tf=tr)   # RRU
                rp = tr((0.05, -0.0, ANT_Z - 0.75)); ap = tf((0.05, 0.0, ANT_Z - 0.76))
                path(bm, uv, [rp, (rp[0], rp[1], ANT_Z - 0.85), (ap[0], ap[1], ANT_Z - 0.85), ap], 0.008, mi=5)
            # feeder from the cable ladder top along the platform to the pole
            path(bm, uv, [(CX0 + 0.1 + k * 0.05, LY + 0.04, TAPER_Z + 0.1), (px * 0.95, py * 0.95, TAPER_Z + 0.1), (px * 0.95, py * 0.95, ANT_Z - 0.8)], 0.012, mi=5)
    # ---- microwave dish (0.6 m) on a short pole on the +X face, facing +X (heading 270)
    DZ = 17.0
    dpx = hw(DZ) + 0.25
    cyl(bm, uv, (dpx, 0.0, DZ - 0.6), (dpx, 0.0, DZ + 0.6), 0.04, sides=8, mi=1)
    for z in (DZ - 0.45, DZ + 0.45):
        for sy in (-1, 1):
            bar(bm, uv, (dpx, 0.0, z), (hw(z), sy * hw(z), z), 0.04, mi=1)
    cyl(bm, uv, (dpx + 0.03, 0, DZ), (dpx + 0.12, 0, DZ), 0.10, sides=10, mi=4)                   # back hub
    cyl(bm, uv, (dpx + 0.12, 0, DZ), (dpx + 0.26, 0, DZ), 0.22, 0.3, sides=16 if detail else 10, mi=3)  # dish shell
    cyl(bm, uv, (dpx + 0.26, 0, DZ), (dpx + 0.31, 0, DZ), 0.3, 0.27, sides=16 if detail else 10, mi=3)  # radome
    # ---- lightning finial
    cyl(bm, uv, (0, 0, TOP), (0, 0, TOP + 0.4), 0.05, sides=8, mi=1)
    cyl(bm, uv, (0, 0, TOP + 0.4), (0, 0, TOP + 2.0), 0.016, 0.006, sides=6, mi=1)
    return bm


def lattice_collision():
    bm, uv = new_bm()
    for sx in (-1, 1):
        for sy in (-1, 1):
            cx, cy = sx * HB, sy * HB
            box(bm, uv, cx - 0.45, cy - 0.45, -0.2, cx + 0.45, cy + 0.45, 0.3, mi=1)
            for za, zb in ((0.3, TAPER_Z), (TAPER_Z, TOP)):
                bar(bm, uv, (sx * (hw(za) - 0.08), sy * (hw(za) - 0.08), za), (sx * (hw(zb) - 0.08), sy * (hw(zb) - 0.08), zb), 0.16, caps=True)
    for face in range(4):
        for i, z in enumerate(LEVELS):
            bar(bm, uv, fpt(face, z, -1), fpt(face, z, 1), 0.09, caps=True)
            if 2 <= i < len(LEVELS) - 1:
                z1 = LEVELS[i + 1]
                bar(bm, uv, fpt(face, z, -1), fpt(face, z1, 1), 0.08, caps=True)
                bar(bm, uv, fpt(face, z, 1), fpt(face, z1, -1), 0.08, caps=True)
    box(bm, uv, -FR, -FR, TAPER_Z - 0.02, FR, FR, TAPER_Z + 0.02)
    h = hw(5.3) - 0.05
    box(bm, uv, -h, -h + 0.7, 5.28, h, h, 5.32)
    box(bm, uv, -0.05, -0.62, 0.4, 0.45, 0.12, 2.6)                                 # ladder cage door block
    for hd in SECTORS:
        px, py = sector_pole(hd)
        fx, fy = heading(hd)
        box(bm, uv, -0.16, -0.06, ANT_Z - 0.7, 0.16, 0.2, ANT_Z + 0.7, tf=orient(px + fx * 0.19, py + fy * 0.19, fx, fy))
    return bm


bmh = build_lattice(True)
nh = len(bmh.faces)
o = finish('opslabs_mast_lattice', bmh, L_MATS())
bml = build_lattice(False)
nl = len(bml.faces)
med = to_mesh('opslabs_mast_lattice_med', bml, L_MATS())
print('LATTICE faces hi', nh, 'med', nl)
add(o, 600.0, ('METAL_SOLID_MEDIUM', 'CONCRETE'), lattice_collision(), med, 150.0)

# ======================================================================= compound
C_MATS = lambda: [mat('opslabs_mst_gravel'), mat('opslabs_mst_grp'), mat('opslabs_mst_cabinfront'), mat('opslabs_mst_timber'),  # noqa: E731
                  mat('opslabs_mst_galv'), mat('opslabs_mst_black'), mat('opslabs_mst_meterfront'), mat('opslabs_mst_concrete'),
                  mat('opslabs_mst_rru')]
FH = 6.5                                                          # fence half size (13 x 13 m)
CAB = (-6.3, -0.25, -4.3, 2.25)                                   # cabin x0, y0, x1, y1
GATE = (1.0, 2.1)                                                 # pedestrian gate opening on the -Y side
SIDE_POSTS = {0: [-6.5, -4.6, -2.7, -0.8, GATE[0], GATE[1], 3.6, 5.05, 6.5]}


def fence_posts(side):
    return SIDE_POSTS.get(side, [-FH + k * (2 * FH / 7) for k in range(8)])


def fence_xy(side, t, out=0.0):
    """side 0 = -Y, 1 = +X, 2 = +Y, 3 = -X ; t = coordinate along the side"""
    return [(t, -FH - out), (FH + out, t), (t, FH + out), (-FH - out, t)][side]


def build_compound(col=False):
    bm, uv = new_bm()
    M = (lambda a, b: b) if col else (lambda a, b: a)               # collision material picker
    if not col:
        # gravel pad (12.9 x 12.9 m, z 0 -> 0.03), cut round the tower pads is unnecessary (pads are higher)
        g = FH - 0.05
        verts = [bm.verts.new(v) for v in ((-g, -g, 0.03), (g, -g, 0.03), (g, g, 0.03), (-g, g, 0.03))]
        f = bm.faces.new(verts); f.material_index = 0
        for loop in f.loops:
            loop[uv].uv = (loop.vert.co.x / 3, loop.vert.co.y / 3)
        for (ax, ay), (bx, by) in (((-g, -g), (g, -g)), ((g, -g), (g, g)), ((g, g), (-g, g)), ((-g, g), (-g, -g))):
            vs = [bm.verts.new(v) for v in ((ax, ay, 0.0), (bx, by, 0.0), (bx, by, 0.03), (ax, ay, 0.03))]
            f = bm.faces.new(vs); f.material_index = 0
            for loop, uvv in zip(f.loops, ((0, 0), (4, 0), (4, 0.02), (0, 0.02))):
                loop[uv].uv = uvv
    # GRP cabin on a concrete base, door on the -Y face
    x0, y0, x1, y1 = CAB
    box(bm, uv, x0 - 0.1, y0 - 0.1, 0.0, x1 + 0.1, y1 + 0.1, 0.15, mi=M(7, 1))
    box(bm, uv, x0, y0, 0.15, x1, y1, 2.35, mi=M(1, 0), front=M(2, 0))
    box(bm, uv, x0 - 0.06, y0 - 0.06, 2.35, x1 + 0.06, y1 + 0.06, 2.45, mi=M(1, 0))    # roof cap
    if not col:
        box(bm, uv, x0 + 0.1, y0 + 0.1, 2.45, x1 - 0.1, y1 - 0.1, 2.48, mi=1)
        box(bm, uv, x0 + 0.25, y0 - 0.04, 0.15, x1 - 0.25, y0, 0.2, mi=7)          # door step
        box(bm, uv, x1, 0.0, 1.95, x1 + 0.05, 0.4, 2.3, mi=8)                       # feeder entry plate
        box(bm, uv, x1, 1.3, 0.8, x1 + 0.35, 2.0, 1.5, mi=8)                         # aircon unit on the tower side
        box(bm, uv, x1 + 0.35, 1.38, 0.88, x1 + 0.36, 1.92, 1.42, mi=5)
    # cable gantry: galvanised tray at z 2.15 from the cabin wall into the tower, two T-posts
    TY0, TY1, TZ = -0.05, 0.25, 2.15
    if col:
        box(bm, uv, x1, TY0, TZ - 0.04, -0.5, TY1, TZ + 0.08, mi=0)
    else:
        for y in (TY0, TY1 - 0.01):
            box(bm, uv, x1, y, TZ, -0.5, y + 0.01, TZ + 0.08, mi=4)
        x = x1 + 0.1
        while x < -0.5:
            box(bm, uv, x, TY0, TZ, x + 0.03, TY1, TZ + 0.01, mi=4)
            x += 0.3
        for k in range(6):
            y = TY0 + 0.05 + k * 0.04
            path(bm, uv, [(x1, y, TZ + 0.06), (-0.55, y, TZ + 0.03), (-0.5 + 0.0, 0.12, 2.25)], 0.014, mi=5)
    for x in (-3.4, -1.95):
        if col:
            box(bm, uv, x - 0.05, 0.05, 0.03, x + 0.05, 0.15, TZ, mi=0)
        else:
            box(bm, uv, x - 0.15, -0.05, 0.03, x + 0.15, 0.25, 0.05, mi=4)
            cyl(bm, uv, (x, 0.1, 0.03), (x, 0.1, TZ - 0.03), 0.045, sides=10, mi=4)
            box(bm, uv, x - 0.04, TY0 - 0.05, TZ - 0.06, x + 0.04, TY1 + 0.05, TZ, mi=4)
    # meter cabinet on a small plinth
    box(bm, uv, -3.75, -1.75, 0.0, -2.85, -1.2, 0.15, mi=M(7, 1))
    box(bm, uv, -3.65, -1.65, 0.15, -2.95, -1.3, 1.1, mi=M(8, 0), front=M(6, 0))
    if not col:
        box(bm, uv, -3.68, -1.68, 1.1, -2.92, -1.27, 1.14, mi=8)
    # timber post-and-rail fence round the compound
    seen = set()
    for side in range(4):
        posts = fence_posts(side)
        for k, t in enumerate(posts):
            px, py = fence_xy(side, t)
            if (round(px, 3), round(py, 3)) in seen:                 # corner posts are shared by two sides
                continue
            seen.add((round(px, 3), round(py, 3)))
            gp = side == 0 and t in GATE
            s = 0.08 if gp else 0.06
            box(bm, uv, px - s, py - s, 0.0, px + s, py + s, 1.3 if gp else 1.25, mi=M(3, 2))
        runs = [(posts[0], GATE[0]), (GATE[1], posts[-1])] if side == 0 else [(posts[0], posts[-1])]
        for a, b in runs:                                    # continuous rails (no overlapping segments)
            for zr in (0.35, 0.72, 1.08):
                p0 = fence_xy(side, a - 0.06, 0.08)
                p1 = fence_xy(side, b + 0.06, 0.08)
                lo = (min(p0[0], p1[0]), min(p0[1], p1[1]))
                hi = (max(p0[0], p1[0]), max(p0[1], p1[1]))
                th = 0.02
                if side in (0, 2):
                    box(bm, uv, lo[0], lo[1] - th, zr - 0.06, hi[0], lo[1] + th, zr + 0.06, mi=M(3, 2))
                else:
                    box(bm, uv, lo[0] - th, lo[1], zr - 0.06, lo[0] + th, hi[1], zr + 0.06, mi=M(3, 2))
    # pedestrian gate leaf (closed), timber frame with a diagonal brace, galvanised hinges + latch
    gx0, gx1, gy = GATE[0] + 0.1, GATE[1] - 0.1, -FH - 0.0
    if col:
        box(bm, uv, gx0, gy - 0.03, 0.1, gx1, gy + 0.03, 1.15, mi=2)
    else:
        for zr in (0.15, 0.62, 1.1):
            box(bm, uv, gx0, gy - 0.025, zr - 0.05, gx1, gy + 0.025, zr + 0.05, mi=3)
        for x in (gx0, gx1 - 0.08):
            box(bm, uv, x, gy - 0.025, 0.1, x + 0.08, gy + 0.025, 1.15, mi=3)
        bar(bm, uv, (gx0 + 0.08, gy - 0.03, 0.18), (gx1 - 0.08, gy - 0.03, 1.07), 0.05, mi=3, caps=True)
        for xs in range(5):
            x = gx0 + 0.15 + xs * 0.14
            box(bm, uv, x, gy + 0.025, 0.1, x + 0.08, gy + 0.04, 1.12, mi=3)      # boards behind
        for z in (0.25, 1.0):
            box(bm, uv, gx0 - 0.02, gy - 0.035, z - 0.02, gx0 + 0.25, gy - 0.025, z + 0.02, mi=4)   # hinges
        box(bm, uv, gx1 - 0.1, gy - 0.04, 1.0, gx1 + 0.1, gy - 0.025, 1.06, mi=4)                  # latch
    return bm


o = finish('opslabs_mast_lattice_compound', build_compound(), C_MATS())
add(o, 300.0, ('METAL_SOLID_MEDIUM', 'CONCRETE', 'WOOD_SOLID_MEDIUM'), build_compound(col=True))

# ======================================================================= 5G monopole
G_MATS = lambda: [mat('opslabs_mst_grey'), mat('opslabs_mst_vent'), mat('opslabs_mst_shroud'), mat('opslabs_mst_rootfront'),  # noqa: E731
                  mat('opslabs_mst_equipfront'), mat('opslabs_mst_equipside'), mat('opslabs_mst_pillarfront'), mat('opslabs_mst_poledoor'),
                  mat('opslabs_mst_concrete'), mat('opslabs_mst_black')]
G_TOP = 17.5
G_ANT = 16.65
R_LO, R_HI, G_STEP = 0.25, 0.175, 7.0
SH0 = 15.7                                                       # shroud bottom
ROOT = (-0.7, -0.5, 0.7, 0.5, 0.1, 1.4)


def build_5g(detail, col=False):
    bm, uv = new_bm()
    S = 20 if detail else 10
    # concrete plinth and cabinets
    box(bm, uv, -0.85, -0.65, 0.0, 3.1, 0.62, 0.1, mi=1 if col else 8)
    x0, y0, x1, y1, z0, z1 = ROOT
    box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=0 if col else 3)                 # root cabinet
    if not col:
        box(bm, uv, x0 - 0.03, y0 - 0.03, z1, x1 + 0.03, y1 + 0.03, z1 + 0.05, mi=0)   # lid
        box(bm, uv, x0 + 0.02, y0 - 0.01, z0, x1 - 0.02, y0, z0 + 0.06, mi=1)        # kick plate
    else:
        box(bm, uv, x0 - 0.03, y0 - 0.03, z1, x1 + 0.03, y1 + 0.03, z1 + 0.05, mi=0)
    box(bm, uv, 0.85, -0.38, 0.1, 2.45, 0.38, 0.22, mi=0 if col else 9)              # black plinth frame
    box(bm, uv, 0.85, -0.4, 0.22, 2.45, 0.4, 1.7, mi=0, front=0 if col else 4, side=0 if col else 5)  # equipment cabinet
    box(bm, uv, 0.83, -0.42, 1.7, 2.47, 0.42, 1.76, mi=0)
    box(bm, uv, 2.55, -0.25, 0.1, 2.95, 0.2, 1.3, mi=0, front=0 if col else 6)        # meter pillar
    box(bm, uv, 2.53, -0.27, 1.3, 2.97, 0.22, 1.34, mi=0)
    zb = ROOT[5] + 0.05
    if col:
        cyl(bm, uv, (0, 0, zb), (0, 0, G_STEP), R_LO, sides=8)
        cyl(bm, uv, (0, 0, G_STEP), (0, 0, SH0), R_HI, sides=8)
        prism(bm, uv, chamfer_sq(0.275, 0.07), SH0, G_TOP)
        return bm
    if detail:
        box(bm, uv, 0.4, -0.15, 0.22, 0.85, 0.15, 0.95, mi=0, front=1)                # small battery / aircon box between
    # pole: lower section, flange, taper, upper section, mid flange
    cyl(bm, uv, (0, 0, zb - 0.02), (0, 0, zb + 0.1), R_LO + 0.06, sides=S, mi=0)    # base collar
    cyl(bm, uv, (0, 0, zb), (0, 0, G_STEP), R_LO, sides=S, mi=0, vrep=4)
    cyl(bm, uv, (0, 0, G_STEP - 0.05), (0, 0, G_STEP + 0.05), R_LO + 0.05, sides=S, mi=0)
    cyl(bm, uv, (0, 0, G_STEP + 0.05), (0, 0, G_STEP + 0.35), R_LO, R_HI, sides=S, mi=0)
    cyl(bm, uv, (0, 0, G_STEP + 0.35), (0, 0, SH0), R_HI, sides=S, mi=0, vrep=4)
    cyl(bm, uv, (0, 0, 11.6), (0, 0, 11.68), R_HI + 0.04, sides=S, mi=0)
    if detail:
        for k in range(12):                                                          # flange bolts
            a = 2 * math.pi * k / 12
            for zf, rf in ((G_STEP, R_LO + 0.04), (11.64, R_HI + 0.03)):
                cyl(bm, uv, (rf * math.cos(a), rf * math.sin(a), zf + 0.04), (rf * math.cos(a), rf * math.sin(a), zf + 0.08), 0.012, sides=6, mi=1)
        box(bm, uv, -0.08, -R_LO - 0.012, 2.2, 0.08, -R_LO + 0.03, 2.75, mi=0, front=7)   # cable access door
        box(bm, uv, -0.08, -R_HI - 0.14, 14.6, 0.08, -R_HI + 0.02, 14.85, mi=0)            # small unit under the shroud
        cyl(bm, uv, (0, -R_HI - 0.07, 14.6), (0, -R_HI - 0.07, 14.3), 0.012, sides=5, mi=9)
    # shroud: chamfered-square, 0.55 m wide, louvres below and above the antenna panel section
    OUTL = chamfer_sq(0.275, 0.07)
    CORE = chamfer_sq(0.22, 0.05)
    cyl(bm, uv, (0, 0, SH0 - 0.05), (0, 0, SH0), R_HI, 0.26, sides=S, mi=0)          # transition cone
    LOUV_LO, PAN_TOP, LOUV_HI = 16.25, 17.05, 17.28
    if detail:
        prism(bm, uv, CORE, SH0, LOUV_LO, mi=1)
        z = SH0
        while z < LOUV_LO - 0.02:
            prism(bm, uv, OUTL, z, z + 0.035, mi=0)
            z += 0.092
        prism(bm, uv, OUTL, LOUV_LO, PAN_TOP, mi=0, side_mi=2)
        prism(bm, uv, CORE, PAN_TOP, LOUV_HI, mi=1)
        z = PAN_TOP + 0.04
        while z < LOUV_HI - 0.02:
            prism(bm, uv, OUTL, z, z + 0.035, mi=0)
            z += 0.08
    else:
        prism(bm, uv, OUTL, SH0, LOUV_LO, mi=1)
        prism(bm, uv, OUTL, LOUV_LO, PAN_TOP, mi=0, side_mi=2)
        prism(bm, uv, CORE, PAN_TOP, LOUV_HI, mi=1)
    TOPB = chamfer_sq(0.25, 0.06)
    prism(bm, uv, TOPB, LOUV_HI, G_TOP - 0.03, mi=0, side_mi=2)                      # top antenna box
    prism(bm, uv, OUTL, G_TOP - 0.03, G_TOP, mi=0)                                   # cap
    if detail:
        for sx in (-1, 1):                                                           # small top mounting rail
            bar(bm, uv, (sx * 0.2, -0.2, G_TOP), (sx * 0.2, -0.2, G_TOP + 0.12), 0.02)
            bar(bm, uv, (sx * 0.2, 0.2, G_TOP), (sx * 0.2, 0.2, G_TOP + 0.12), 0.02)
        for sy in (-1, 1):
            bar(bm, uv, (-0.2, sy * 0.2, G_TOP + 0.12), (0.2, sy * 0.2, G_TOP + 0.12), 0.02)
    return bm


o = finish('opslabs_mast_5g', build_5g(True), G_MATS())
med = to_mesh('opslabs_mast_5g_med', build_5g(False), G_MATS())
add(o, 600.0, ('METAL_SOLID_MEDIUM', 'CONCRETE'), build_5g(True, col=True), med, 150.0)

# ======================================================================= Sollumz conversion
scene = bpy.context.scene
scene.create_seperate_drawables = True
drawables = []
for m in models:
    obj = m['obj']
    scene.auto_create_embedded_col = m['colmat'] is not None
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.sollumz.converttodrawable()
    d = obj.parent
    drawables.append((d, m['lod']))
    if m['med'] is not None:
        obj.sz_lods.get_lod(sz_props.LODLevel.MEDIUM).mesh = m['med']
        d.drawable_properties.lod_dist_high = m['lod_hi']
        d.drawable_properties.lod_dist_med = m['lod']
        d.drawable_properties.lod_dist_low = m['lod']
        d.drawable_properties.lod_dist_vlow = m['lod']
    if m['colmat']:
        cms = []
        for name in m['colmat']:
            idx = next((i for i, cm in enumerate(sz_col.collisionmats) if cm.name == name), 0)
            cms.append(sz_col.create_collision_material_from_index(idx))
        for child in d.children_recursive:
            if child.type == 'MESH' and 'poly_mesh' in child.name:
                if m['colmesh'] is not None:
                    bmc = m['colmesh']
                    bmesh.ops.remove_doubles(bmc, verts=bmc.verts, dist=1e-6)
                    cme = bpy.data.meshes.new(child.name + '_col')
                    bmc.to_mesh(cme)
                    bmc.free()
                    old = child.data
                    child.data = cme
                    bpy.data.meshes.remove(old)
                    print('COLLISION', d.name, child.name, 'faces', len(cme.polygons), 'loc', tuple(child.matrix_world.translation))
                child.data.materials.clear()
                for cm in cms:
                    child.data.materials.append(cm)
bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_mast_props'
bpy.ops.object.select_all(action='DESELECT')
for d, _ in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0][0]
bpy.ops.sollumz.createarchetypefromselected()
lods = {d.name: lod for d, lod in drawables}
for a in ytyp.archetypes:
    a.lod_dist = lods.get(a.name, 300.0)
print('ARCHETYPES', [(a.name, a.lod_dist) for a in ytyp.archetypes])
res = bpy.ops.sollumz.export_assets(directory=OUT, direct_export=True, use_custom_settings=True,
                                    target_formats={'CWXML'}, target_versions={'GEN8'}, limit_to_selected=False, export_ytyps=True)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_masts.blend'))
