"""Underground telecom structures (walk-in, with collision), placed UNDER roads / pavements.
Every origin is on the road surface (z = 0) and the structure hangs below it.
  opslabs_ug_chamber     precast jointing chamber, outer 3.6 x 3.6 (+-1.8), walls 0.2 (interior +-1.6),
                         roof slab -0.27 .. -0.02, floor top -3.00 (slab to -3.25). Access opening 0.8 x 0.8 through
                         the roof centred (-1.0, -1.15) with a galvanised frame (top +0.015). Step irons on the inside
                         of the -Y wall at x = -1.0, z -2.70 .. -0.45, 0.12 out. A 2.0 x 2.2 tunnel opening centred in
                         every wall (z -3.00 .. -0.80). Cable bearers + black / yellow bundles looping round above the
                         openings, joint closure on a bracket, ceiling bulkhead lamp (0.6, 0.6, ~-0.4), DANGER sign.
  opslabs_ug_hatch_lid   chequer-plate lid; origin = hinge edge: x 0 .. 0.80, y +-0.40, z 0 .. 0.03. Rotate about Y.
  opslabs_ug_tunnel      4.0 m straight cable tunnel along Y (y +-2.0), interior x +-1.0, z -3.00 .. -0.80,
                         walls 0.2, roof -0.80 .. -0.55, floor -3.20 .. -3.00. Trays at z -1.40 / -2.00 both walls,
                         LED battens centred y -1.0 / +1.0 (x 0, just under the ceiling), pipes on the -X floor edge.
  opslabs_ug_tunnel_end  end wall x +-1.2, y 0 .. 0.20, z -3.05 .. -0.55 with a capped 3-duct entry boss on its -Y face.
  opslabs_ug_riser       HDPE duct d 0.11 from z -0.85 (flange under the ceiling) up to +0.90, goose-neck facing -Y,
                         cap + gland at (0, -0.22, 1.05); concrete collar d 0.3 at z -0.02 .. 0.06. Origin = pipe centre.
  opslabs_ug_riser_flush same duct ending just above ground (+0.05) in a flush cap (top +0.075) with a gland.
  opslabs_ug_entrance    street access: 2.0 x 2.0 x 2.4 green GRP kiosk (door -Y, x +-0.45, z 0.05 .. 2.05) over a
                         chamber-sized stairwell (one 2.0 x 2.2 opening in +Y); stair x -1.4 .. -0.4 from the top landing
                         (z -0.30, y -1.6 .. -1.35) down to the floor at y +0.60; landing clear round (-0.9, +1.0).
  opslabs_ug_tunnel_tee  the tunnel section with a 2.0 x 2.2 side opening through the +X wall (y +-1.0, z -3.00 .. -0.80);
                         +X tray cables turn up and cross the opening just under the ceiling (z -0.82 .. -0.895).
blender -b --python build_underground.py -- <out_dir>
"""
import math
import os
import random
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
exec(open(os.path.join(HERE, 'canvas_lib.py')).read())

YTYP_NAME = 'opslabs_underground_props'
LOD = 150.0


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


FONT = {
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'], 'C': ['01110', '10001', '10000', '10000', '10000', '10001', '01110'],
    'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'], 'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
    'F': ['11111', '10000', '10000', '11110', '10000', '10000', '10000'], 'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01111'],
    'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'], 'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'],
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], 'P': ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
    'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'], 'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
    'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], 'Y': ['10001', '10001', '01010', '00100', '00100', '00100', '00100'],
    'L': ['10000', '10000', '10000', '10000', '10000', '10000', '11111'], 'M': ['10001', '11011', '10101', '10101', '10001', '10001', '10001'],
    'U': ['10001', '10001', '10001', '10001', '10001', '10001', '01110'], 'W': ['10001', '10001', '10001', '10101', '10101', '11011', '10001'],
    '!': ['00100', '00100', '00100', '00100', '00100', '00000', '00100'], ' ': ['00000'] * 7,
}


def text(c, s, x, y, scale, col):
    """draw s centred on x, top at y"""
    w = len(s) * 6 * scale - scale
    x0 = int(x - w / 2)
    for i, ch in enumerate(s):
        g = FONT[ch]
        for r, row in enumerate(g):
            for k, bit in enumerate(row):
                if bit == '1':
                    c.rect(x0 + (i * 6 + k) * scale, y + r * scale, x0 + (i * 6 + k + 1) * scale, y + (r + 1) * scale, col)


# ---------------------------------------------------------------- textures
rnd = random.Random(11)
# rough cast concrete walls (512 px over 4 m): formwork board lines, pores, a few damp / rust stains
c = Canvas(512, 512, (150, 149, 143))
for y in range(0, 512, 77):
    c.rect(0, y, 512, y + 1, (136, 135, 130))                                              # shuttering lines
for _ in range(60):                                                                        # mottling
    x, y, r = rnd.randrange(512), rnd.randrange(512), rnd.randrange(10, 40)
    c.circle(x, y, r, (138, 137, 132) if rnd.random() < 0.5 else (160, 159, 153), 0.25)
for _ in range(900):                                                                       # blow holes
    x, y = rnd.randrange(512), rnd.randrange(512)
    c.rect(x, y, x + rnd.choice((1, 2)), y + rnd.choice((1, 2)), (96, 96, 92), 0.8)
for x0, y0, ln, col in ((70, 40, 260, (112, 108, 98)), (300, 120, 330, (120, 104, 84)), (430, 10, 180, (110, 110, 104))):
    for k in range(ln):                                                                    # drip / damp streaks
        w = 10 + int(6 * math.sin(k * 0.05))
        c.rect(x0 - w // 2 + int(3 * math.sin(k * 0.13)), (y0 + k) % 512, x0 + w // 2, (y0 + k) % 512 + 1, col, 0.35 * (1 - k / ln))
c.rect(0, 470, 512, 512, (118, 118, 112), 0.35)                                            # tide mark low on the wall
c.noise(12); save(c, 'opslabs_ug_wall')
# darker damp floor (512 px over 4 m) with puddles
c = Canvas(512, 512, (92, 92, 88))
for _ in range(40):
    x, y, r = rnd.randrange(512), rnd.randrange(512), rnd.randrange(12, 50)
    c.circle(x, y, r, (70, 72, 70), 0.45)
for _ in range(500):
    x, y = rnd.randrange(512), rnd.randrange(512)
    c.rect(x, y, x + 2, y + 1, (120, 118, 112), 0.6)                                       # grit
c.noise(10); save(c, 'opslabs_ug_floor')
c = Canvas(64, 64, (40, 42, 40)); c.circle(32, 32, 20, (28, 34, 34)); c.noise(6); save(c, 'opslabs_ug_sump')    # wet sump
c = Canvas(64, 64, (112, 112, 108)); c.noise(8); save(c, 'opslabs_ug_joint')               # mortar joint strip
c = Canvas(64, 64, (162, 166, 170)); c.noise(12); save(c, 'opslabs_ug_galv')
c = Canvas(16, 256, (24, 24, 26)); c.rect(5, 0, 8, 256, (52, 52, 56)); c.noise(2); save(c, 'opslabs_ug_cable_black')
c = Canvas(16, 256, (226, 186, 20)); c.rect(5, 0, 8, 256, (246, 214, 70)); c.noise(3); save(c, 'opslabs_ug_cable_yellow')
c = Canvas(16, 256, (128, 130, 132)); c.rect(5, 0, 8, 256, (160, 162, 164)); c.noise(3); save(c, 'opslabs_ug_cable_grey')
c = Canvas(64, 64, (26, 26, 28)); c.noise(3); save(c, 'opslabs_ug_black')
c = Canvas(64, 64, (70, 72, 74)); c.noise(4); save(c, 'opslabs_ug_lampbody')
c = Canvas(32, 32, (255, 226, 170)); save(c, 'opslabs_ug_glow_warm')
c = Canvas(32, 32, (226, 238, 255)); save(c, 'opslabs_ug_glow_cool')
c = Canvas(64, 64, (124, 128, 130)); c.noise(4); save(c, 'opslabs_ug_duct')
c = Canvas(64, 64, (200, 34, 30)); c.noise(4); save(c, 'opslabs_ug_red')
c = Canvas(64, 64, (236, 196, 24)); c.noise(5); save(c, 'opslabs_ug_yellow')
# DANGER confined space sign (256 x 192 for a 0.30 x 0.225 plate)
c = Canvas(256, 192, (244, 204, 22))
c.rect(0, 0, 256, 6, (20, 20, 20)); c.rect(0, 186, 256, 192, (20, 20, 20)); c.rect(0, 0, 6, 192, (20, 20, 20)); c.rect(250, 0, 256, 192, (20, 20, 20))
for r in range(60):                                                                        # warning triangle
    w = int(r * 0.62)
    c.rect(128 - w, 14 + r, 128 + w, 15 + r, (20, 20, 20))
for r in range(44):
    w = int(r * 0.62)
    c.rect(128 - w, 26 + r, 128 + w, 27 + r, (244, 204, 22))
text(c, '!', 128, 40, 4, (20, 20, 20))
text(c, 'DANGER', 128, 84, 5, (20, 20, 20))
text(c, 'CONFINED SPACE', 128, 134, 3, (20, 20, 20))
text(c, 'PERMIT ONLY', 128, 162, 2, (20, 20, 20))
save(c, 'opslabs_ug_sign')
# chequer-plate lid top (256 px over 0.8 m): yellow painted edge, lozenge pattern, lifting keyhole near the free edge
c = Canvas(256, 256, (128, 131, 134))
for gy in range(0, 256, 12):
    for gx in range(0, 256, 12):
        o = (gx // 12 + gy // 12) % 2
        if o:
            c.rect(gx + 3, gy + 5, gx + 10, gy + 7, (176, 180, 184)); c.rect(gx + 3, gy + 7, gx + 10, gy + 8, (84, 86, 88))
        else:
            c.rect(gx + 5, gy + 2, gx + 7, gy + 10, (176, 180, 184)); c.rect(gx + 7, gy + 2, gx + 8, gy + 10, (84, 86, 88))
c.rect(0, 0, 256, 11, (236, 196, 24)); c.rect(0, 245, 256, 256, (236, 196, 24))
c.rect(0, 0, 11, 256, (236, 196, 24)); c.rect(245, 0, 256, 256, (236, 196, 24))
c.rrect(208, 122, 236, 134, 5, (16, 16, 16)); c.circle(232, 128, 9, (16, 16, 16))         # keyhole (u 0.875)
c.rrect(204, 118, 240, 138, 8, (90, 92, 94), 0.3)
c.noise(6); save(c, 'opslabs_ug_chequer')

# fake-depth insert for the open hatch (the game's road can't be holed): looking straight down a 3 m shaft,
# walls converging to a dim damp floor, step irons down the -Y side (bottom of the image), warm lamp glow on +X
c = Canvas(256, 256, (0, 0, 0))
EYE, A = 1.5, 1.5 / 4.5                                                                 # eye height above the top, floor scale
for row in range(256):
    for col in range(256):
        u, v = (col + 0.5) / 128 - 1, 1 - (row + 0.5) / 128
        m = max(abs(u), abs(v))
        if m <= A:
            t = 1.0; base = (62, 63, 60)
            if math.hypot(u - 0.08, v + 0.05) < 0.12:
                base = (44, 47, 47)                                                      # puddle
        else:
            d = EYE / m - EYE                                                            # depth 0 .. 3 m on the wall
            t = d / 3.0
            base = (150, 149, 143)
            if abs(v) > abs(u):                                                          # +-Y walls a touch darker
                base = (138, 137, 131)
            if int(d / 0.6) % 2 == 0 and (d % 0.6) < 0.015:
                base = (120, 119, 114)                                                   # shuttering line
        k = 1.0 - 0.72 * t
        k *= 1.0 - 0.35 * max(0.0, m - 0.75) / 0.25                                      # vignette at the rim
        warm = max(0.0, u) * 0.35 * (1 - abs(t - 0.6))                                   # chamber lamp glow on the +X side
        p = c.px[row * 256 + col]
        p[0] = min(255, int(base[0] * k + 60 * warm)); p[1] = min(255, int(base[1] * k + 44 * warm)); p[2] = min(255, int(base[2] * k + 20 * warm))


def _pt(u, v):
    return int((u + 1) * 128), int((1 - v) * 128)


for d in [0.45, 0.60, 0.90, 1.20, 1.50, 1.80, 2.10, 2.40, 2.70]:  # step irons (depth below top)
    sc_ = EYE / (EYE + d)
    g = int(200 * (1 - 0.7 * d / 3.0))
    x0, y0 = _pt(-0.375 * sc_, -0.70 * sc_); x1, _ = _pt(0.375 * sc_, -0.70 * sc_)
    th = max(1, int(4 * sc_))
    c.rect(x0, y0 - th // 2, x1 + 1, y0 + th // 2 + 1, (g, g, g + 4))                   # rung
    c.rect(x0, y0 + th // 2 + 1, x1 + 1, y0 + th // 2 + 2, (20, 20, 20), 0.5)           # its shadow
    for su in (-0.375, 0.375):
        a_, b_ = _pt(su * sc_, -sc_), _pt(su * sc_, -0.70 * sc_)
        c.rect(a_[0] - th // 2, b_[1], a_[0] + th // 2 + 1, a_[1], (int(g * 0.8),) * 3)   # legs back to the wall
for i in range(200):                                                                     # stringers down the -Y wall
    m_ = 1 - i / 200 * (1 - A)
    for su in (-0.42, 0.42):
        x, y = _pt(su * m_, -m_)
        g = int(170 * (0.3 + 0.7 * m_))
        c.rect(x - 1, y - 1, x + 1, y + 1, (g, g, g))
c.noise(4); save(c, 'opslabs_ug_shaftfake')

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


def finish(name, bm, mats):
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    col = me.color_attributes.new('Color 1', 'BYTE_COLOR', 'CORNER')
    for d in col.data:
        d.color = (1, 1, 1, 1)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, tile=None, fmi=None, skip=()):
    """box; tile = world-planar UVs (metres per texture repeat), else 0..1 per face. fmi = {face: mat index}"""
    F = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    fmi = fmi or {}
    for k, vs in F.items():
        if k in skip:
            continue
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = fmi.get(k, mi)
        for loop, u, v in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1)), vs):
            if tile:
                if k in ('front', 'back'):
                    loop[uv].uv = (v[0] / tile, v[2] / tile)
                elif k in ('left', 'right'):
                    loop[uv].uv = (v[1] / tile, v[2] / tile)
                else:
                    loop[uv].uv = (v[0] / tile, v[1] / tile)
            else:
                loop[uv].uv = u


def quad(bm, uv, vs, mi=0, tile=None, axes=(0, 1)):
    f = bm.faces.new([bm.verts.new(v) for v in vs])
    f.material_index = mi
    for loop, u, v in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1)), vs):
        loop[uv].uv = (v[axes[0]] / tile, v[axes[1]] / tile) if tile else u


def cyl(bm, uv, p0, p1, r0, r1=None, sides=12, mi=0, vrep=1.0, caps=True):
    r1 = r0 if r1 is None else r1
    a, b = mathutils.Vector(p0), mathutils.Vector(p1)
    d = (b - a).normalized()
    t = mathutils.Vector((1, 0, 0)) if abs(d.x) < 0.9 else mathutils.Vector((0, 1, 0))
    u = d.cross(t).normalized()
    w = d.cross(u).normalized()
    rings = [[bm.verts.new(c + (u * math.cos(2 * math.pi * i / sides) + w * math.sin(2 * math.pi * i / sides)) * r) for i in range(sides)] for c, r in ((a, r0), (b, r1))]
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
        f.material_index = mi
        f.smooth = True
        for loop, uvv in zip(f.loops, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, vrep), (i / sides, vrep))):
            loop[uv].uv = uvv
    if caps:
        for k, ring in enumerate(rings):
            if (r0 if k == 0 else r1) > 0.0005:
                f = bm.faces.new(ring if k else list(reversed(ring)))
                f.material_index = mi
                for loop in f.loops:
                    loop[uv].uv = (0.5, 0.5)


def cable(bm, uv, pts, r, mi, sides=8):
    """a cable along a polyline; segments overlap by r so the bends close up"""
    for p, q in zip(pts, pts[1:]):
        a, b = mathutils.Vector(p), mathutils.Vector(q)
        L = (b - a).length
        if L < 1e-6:
            continue
        d = (b - a) / L
        cyl(bm, uv, tuple(a - d * r * 0.9), tuple(b + d * r * 0.9), r, sides=sides, mi=mi, vrep=L * 2)


# ---------------------------------------------------------------- collision meshes
COLMATS = ['CONCRETE', 'METAL_SOLID_MEDIUM', 'METAL_MANHOLE', 'PLASTIC']


def cbox(cb, x0, y0, z0, x1, y1, z1, mi=0):
    vs = [cb.verts.new(v) for v in ((x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0), (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1))]
    for idx in ((0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)):
        f = cb.faces.new([vs[i] for i in idx])
        f.material_index = mi


def colmesh(name, cb):
    me = bpy.data.meshes.new(name + '_col')
    cb.to_mesh(me)
    cb.free()
    for n in COLMATS:
        idx = next(i for i, m in enumerate(sz_col.collisionmats) if m.name == n)
        me.materials.append(sz_col.create_collision_material_from_index(idx))
    return me


models = []


def add(obj, colme=None):
    models.append((obj, colme))


WT = 4.0          # concrete texture: metres per repeat
CON, FLR, GALV, CBK, CYL, CGR, BLK, LAMP, GLOW, SIGN, SUMP, JOINT, DUCT, RED = range(14)
CHAMBER_MATS = lambda: [mat('opslabs_ug_wall'), mat('opslabs_ug_floor'), mat('opslabs_ug_galv'), mat('opslabs_ug_cable_black'),
                        mat('opslabs_ug_cable_yellow'), mat('opslabs_ug_cable_grey'), mat('opslabs_ug_black'), mat('opslabs_ug_lampbody'),
                        mat('opslabs_ug_glow_warm', 'emissive.sps'), mat('opslabs_ug_sign'), mat('opslabs_ug_sump'), mat('opslabs_ug_joint'),
                        mat('opslabs_ug_wall'), mat('opslabs_ug_shaftfake')]               # 12 unused here, 13 = SHAFT insert

# ================================================================ 1. chamber
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()
OI, OO = 1.6, 1.8                    # interior / outer half size
RB, RT = -0.27, -0.02                # roof slab bottom / top
FT, FB = -3.00, -3.25                # floor top / slab bottom
OW, OT = 1.0, -0.80                  # opening half width / top
HX0, HX1, HY0, HY1 = -1.4, -0.6, -1.55, -0.75   # roof access opening (centre -1.0, -1.15)
SX0, SX1, SY0, SY1, SZ = 1.05, 1.40, -1.40, -1.05, -3.18   # sump


def wbox(x0, y0, z0, x1, y1, z1, mi=CON, colm=0, vis=True):
    if vis:
        box(bm, uv, x0, y0, z0, x1, y1, z1, mi=mi, tile=WT)
    cbox(cb, x0, y0, z0, x1, y1, z1, colm)


# floor slab around the sump (collision: the whole slab)
for b in ((-OO, -OO, SX0, OO), (SX0, -OO, SX1, SY0), (SX0, SY1, SX1, OO), (SX1, -OO, OO, OO)):
    box(bm, uv, b[0], b[1], FB, b[2], b[3], FT, mi=FLR, tile=WT, fmi={'front': SUMP, 'back': SUMP, 'left': SUMP, 'right': SUMP})
cbox(cb, -OO, -OO, FB, OO, OO, FT, 0)
quad(bm, uv, [(SX0, SY0, SZ), (SX1, SY0, SZ), (SX1, SY1, SZ), (SX0, SY1, SZ)], mi=SUMP)
for k in range(8):                                                                     # sump grating (flush)
    x = SX0 + 0.02 + k * (SX1 - SX0 - 0.04) / 7
    box(bm, uv, x - 0.004, SY0, FT - 0.025, x + 0.004, SY1, FT - 0.002, mi=GALV)
for y in (SY0 + 0.01, SY1 - 0.01):
    box(bm, uv, SX0, y - 0.01, FT - 0.03, SX1, y + 0.01, FT - 0.002, mi=GALV)
# walls: -Y / +Y span the full outer width, -X / +X fit between them; a 2.0 x 2.2 opening centred in each
for sy in (-1, 1):
    y0, y1 = (-OO, -OI) if sy < 0 else (OI, OO)
    wbox(-OO, y0, FT, -OW, y1, RB); wbox(OW, y0, FT, OO, y1, RB); wbox(-OW, y0, OT, OW, y1, RB)
for sx in (-1, 1):
    x0, x1 = (-OO, -OI) if sx < 0 else (OI, OO)
    wbox(x0, -OI, FT, x1, -OW, RB); wbox(x0, OW, FT, x1, OI, RB); wbox(x0, -OW, OT, x1, OW, RB)
# roof slab with the access opening
wbox(-OO, -OO, RB, HX0, OO, RT); wbox(HX1, -OO, RB, OO, OO, RT)
wbox(HX0, -OO, RB, HX1, HY0, RT); wbox(HX0, HY1, RB, HX1, OO, RT)
# galvanised frame: flange on the road (top +0.015) round the opening, lip down the shaft, seat ledge for the lid
FL = 0.07
for b in ((HX0 - FL, HY0 - FL, HX1 + FL, HY0), (HX0 - FL, HY1, HX1 + FL, HY1 + FL), (HX0 - FL, HY0, HX0, HY1), (HX1, HY0, HX1 + FL, HY1)):
    box(bm, uv, b[0], b[1], RT, b[2], b[3], 0.015, mi=GALV)
    cbox(cb, b[0], b[1], RT, b[2], b[3], 0.015, 1)
for b in ((HX0, HY0, HX1, HY0 + 0.006), (HX0, HY1 - 0.006, HX1, HY1), (HX0, HY0, HX0 + 0.006, HY1), (HX1 - 0.006, HY0, HX1, HY1)):
    box(bm, uv, b[0], b[1], -0.12, b[2], b[3], RT, mi=GALV)
for b in ((HX0, HY0, HX1, HY0 + 0.022), (HX0, HY1 - 0.022, HX1, HY1), (HX0, HY0, HX0 + 0.022, HY1), (HX1 - 0.022, HY0, HX1, HY1)):
    box(bm, uv, b[0], b[1], -0.012, b[2], b[3], -0.002, mi=GALV)
# fake-depth insert filling the clear opening (inside the frame lip) at z +0.010: single-sided, facing up, no collision
quad(bm, uv, [(HX0 + 0.006, HY0 + 0.006, 0.010), (HX1 - 0.006, HY0 + 0.006, 0.010), (HX1 - 0.006, HY1 - 0.006, 0.010), (HX0 + 0.006, HY1 - 0.006, 0.010)], mi=13)
# step irons on the -Y wall at x = -1.0: two galvanised flat stringers (the right one stands proud in front of the
# tunnel opening's edge) and U-rungs 0.12 out from the wall face, z -2.70 .. -0.60 every 0.30 plus a top rung at -0.45
IX, IY = -1.0, -OI
RUNGS = [round(-2.70 + 0.30 * k, 2) for k in range(8)] + [-0.45]
for x in (IX - 0.19, IX + 0.15):
    box(bm, uv, x, IY, FT, x + 0.04, IY + 0.05, -0.30, mi=GALV)
    cbox(cb, x, IY, FT, x + 0.04, IY + 0.05, -0.30, 1)
for z in RUNGS:
    cable(bm, uv, [(IX - 0.15, IY + 0.05, z), (IX - 0.15, IY + 0.12, z), (IX + 0.15, IY + 0.12, z), (IX + 0.15, IY + 0.05, z)], 0.0125, GALV, sides=8)
    cbox(cb, IX - 0.16, IY + 0.05, z - 0.013, IX + 0.16, IY + 0.133, z + 0.013, 1)
for z in (-2.95, -0.32):                                                               # stringer fixings
    box(bm, uv, IX - 0.21, IY, z - 0.02, IX + 0.21, IY + 0.012, z + 0.02, mi=GALV)
# DANGER confined space sign, left of the irons
box(bm, uv, -1.58, IY, -1.52, -1.28, IY + 0.006, -1.295, mi=SIGN, fmi={'front': GALV, 'left': GALV, 'right': GALV, 'top': GALV, 'bottom': GALV})


def wall_pt(w, s, n, z):
    """wall-local -> chamber: s along the wall, n = distance out from the inside face into the room"""
    return {'-Y': (s, -OI + n, z), '+Y': (s, OI - n, z), '-X': (-OI + n, s, z), '+X': (OI - n, s, z)}[w]


def wall_box(w, s0, s1, n0, n1, z0, z1, mi):
    a, b = wall_pt(w, s0, n0, z0), wall_pt(w, s1, n1, z1)
    box(bm, uv, min(a[0], b[0]), min(a[1], b[1]), z0, max(a[0], b[0]), max(a[1], b[1]), z1, mi=mi)


# cable bearers: galvanised channel strips on the lintels and (full height) on the wall sections beside the openings,
# hook arms under each bundle level
LEVELS = (-0.47, -0.585, -0.725)
for w in ('-Y', '+Y', '-X', '+X'):
    for s in (-1.3, -0.5, 0.5, 1.3):
        full = abs(s) > OW and not (w == '-Y' and s < 0) and not (w == '+X' and s > 0)
        wall_box(w, s - 0.02, s + 0.02, 0.0, 0.04, -2.85 if full else OT + 0.03, RB - 0.03, GALV)
        for z in LEVELS:
            wall_box(w, s - 0.012, s + 0.012, 0.04, 0.16, z - 0.012, z, GALV)
            wall_box(w, s - 0.012, s + 0.012, 0.15, 0.16, z, z + 0.03, GALV)
# bundles looping round the chamber above the openings (all above z -0.9)
LOOP = [  # (inset, z, radius, mat)
    (0.07, -0.445, 0.014, CBK), (0.10, -0.448, 0.014, CBK), (0.13, -0.445, 0.012, CBK), (0.085, -0.425, 0.012, CBK),
    (0.07, -0.565, 0.012, CYL), (0.095, -0.567, 0.012, CYL), (0.12, -0.565, 0.012, CYL),
    (0.075, -0.70, 0.02, CBK), (0.12, -0.70, 0.018, CBK), (0.10, -0.67, 0.012, CGR),
]
for d, z, r, mi in LOOP:
    e = OI - d
    ch = 0.12 - d * 0.5                                                                # chamfered corners
    corners = [(-e, -e), (e, -e), (e, e), (-e, e)]
    pts = []
    for i in range(4):
        (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
        dx, dy = (bx - ax) / (2 * e), (by - ay) / (2 * e)
        pts.append((ax + dx * ch, ay + dy * ch, z))
        pts.append((bx - dx * ch, by - dy * ch, z))
    pts.append(pts[0])
    cable(bm, uv, pts, r, mi)
# risers: cables come in through each opening at the tunnel tray levels, turn along the wall and rise to the loop
for w in ('-Y', '+Y', '-X', '+X'):
    for sg in (-1, 1):
        if w == '-Y' and sg < 0:
            continue                                                                   # step irons there
        for zt, mi, dn, ds, r in ((-1.38, CBK, 0.06, 1.07, 0.016), (-1.38, CGR, 0.10, 1.11, 0.012), (-1.98, CYL, 0.08, 1.15, 0.014)):
            sz = sg * (0.82 + (ds - 1.07))
            pts = [wall_pt(w, sz, -0.2, zt), wall_pt(w, sz, dn - 0.02, zt), wall_pt(w, sg * ds, dn, zt + 0.06),
                   wall_pt(w, sg * ds, dn, -0.62), wall_pt(w, sg * (ds - 0.1), dn + 0.01, -0.70 if mi != CYL else -0.565)]
            cable(bm, uv, pts, r, mi)
# joint closure on a bracket (+X wall, +Y corner) with cable tails looping up to the loop and down in a slack loop
JX, JY = OI - 0.25, 1.33
box(bm, uv, OI - 0.012, JY - 0.11, -1.85, OI, JY + 0.11, -1.05, mi=GALV)                # back plate
for z in (-1.70, -1.20):
    box(bm, uv, JX + 0.06, JY - 0.02, z - 0.015, OI - 0.012, JY + 0.02, z + 0.015, mi=GALV)   # stand-off arms
    cyl(bm, uv, (JX, JY, z - 0.02), (JX, JY, z + 0.02), 0.098, sides=20, mi=GALV)      # clamp bands
cyl(bm, uv, (JX, JY, -1.78), (JX, JY, -1.12), 0.09, sides=20, mi=BLK)                  # closure dome
cyl(bm, uv, (JX, JY, -1.12), (JX, JY, -1.06), 0.09, 0.05, sides=20, mi=BLK)
cyl(bm, uv, (JX, JY, -1.78), (JX, JY, -1.84), 0.1, 0.1, sides=20, mi=BLK)              # base + clamp ring
cyl(bm, uv, (JX, JY, -1.765), (JX, JY, -1.795), 0.102, sides=20, mi=CGR)
for k, (dy, mi, r) in enumerate(((-0.04, CBK, 0.016), (0.0, CYL, 0.012), (0.045, CBK, 0.016))):
    cable(bm, uv, [(JX + 0.02, JY + dy, -1.84), (JX + 0.02, JY + dy, -2.20 - k * 0.04), (JX + 0.12 + k * 0.02, JY + dy * 0.5 - 0.15, -2.30 - k * 0.04),
                   (OI - 0.07 - k * 0.025, JY - 0.22, -2.1), (OI - 0.07 - k * 0.025, JY - 0.24, -0.66), (OI - 0.09 - k * 0.02, JY - 0.12, -0.70)], r, mi)
# bulkhead lamp on the ceiling at (0.6, 0.6): base, warm lens (emissive, bottom ~ -0.40), guard bars, conduit to the wall
LX, LY = 0.6, 0.6
box(bm, uv, LX - 0.16, LY - 0.10, RB - 0.06, LX + 0.16, LY + 0.10, RB, mi=LAMP)
box(bm, uv, LX - 0.13, LY - 0.075, -0.395, LX + 0.13, LY + 0.075, RB - 0.06, mi=GLOW)
for dy in (-0.08, 0.0, 0.08):
    cable(bm, uv, [(LX - 0.14, LY + dy, RB - 0.06), (LX - 0.14, LY + dy, -0.405), (LX + 0.14, LY + dy, -0.405), (LX + 0.14, LY + dy, RB - 0.06)], 0.005, LAMP, sides=5)
cyl(bm, uv, (LX + 0.16, LY, RB - 0.02), (OI, LY, RB - 0.02), 0.012, sides=8, mi=GALV)
for x in (0.95, 1.3):
    box(bm, uv, x - 0.015, LY - 0.02, RB - 0.04, x + 0.015, LY + 0.02, RB, mi=GALV)
add(finish('opslabs_ug_chamber', bm, CHAMBER_MATS()), colmesh('opslabs_ug_chamber', cb))

# ================================================================ 2. hatch lid (origin = hinge edge)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()
box(bm, uv, 0.0, -0.40, 0.0, 0.80, 0.40, 0.03, mi=1, fmi={'top': 0, 'bottom': 2})
box(bm, uv, 0.665, -0.007, 0.03, 0.725, 0.007, 0.0304, mi=3)                           # keyhole slot (dark, matches texture)
for y0, y1 in ((-0.33, -0.21), (0.21, 0.33)):
    cyl(bm, uv, (0.0, y0, 0.015), (0.0, y1, 0.015), 0.019, sides=12, mi=2)             # hinge knuckles at x = 0
    box(bm, uv, 0.0, y0 + 0.01, 0.03, 0.09, y1 - 0.01, 0.034, mi=2)                    # hinge leaves
    cyl(bm, uv, (0.0, y0 - 0.006, 0.015), (0.0, y1 + 0.006, 0.015), 0.007, sides=8, mi=2)   # pin
for y in (-0.12, 0.12):
    box(bm, uv, 0.06, y - 0.01, -0.0, 0.74, y + 0.01, 0.0005, mi=2)                    # underside stiffener lines
cbox(cb, 0.0, -0.40, 0.0, 0.80, 0.40, 0.03, 2)
cbox(cb, -0.019, -0.33, -0.004, 0.019, 0.33, 0.034, 2)
add(finish('opslabs_ug_hatch_lid', bm, [mat('opslabs_ug_chequer'), mat('opslabs_ug_yellow'), mat('opslabs_ug_galv'), mat('opslabs_ug_black')]),
    colmesh('opslabs_ug_hatch_lid', cb))

# ================================================================ 3. tunnel section
L2, TI, TO, TC, TR, TF, TB = 2.0, 1.0, 1.2, -0.80, -0.55, -3.00, -3.20


def build_tunnel(name, tee=False):
    """straight section; tee = 2.0 x 2.2 side opening through the +X wall centred at y = 0"""
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()

    def tbox(x0, y0, z0, x1, y1, z1, mi=CON, colm=0):
        box(bm, uv, x0, y0, z0, x1, y1, z1, mi=mi, tile=WT, skip=('front', 'back'))      # open ends: no end caps
        cbox(cb, x0, y0, z0, x1, y1, z1, colm)


    tbox(-TO, -L2, TB, TO, L2, TF, mi=FLR)
    tbox(-TO, -L2, TC, TO, L2, TR)
    tbox(-TO, -L2, TF, -TI, L2, TC)
    if tee:                                                                                  # +X wall with the 2.0 x 2.2 side opening
        tbox(TI, -L2, TF, TO, -1.0, TC); tbox(TI, 1.0, TF, TO, L2, TC)
        for y, fl in ((-1.0, 1), (1.0, 0)):                                                  # opening reveals
            vs = [(TI, y, TF), (TO, y, TF), (TO, y, TC), (TI, y, TC)]
            quad(bm, uv, vs if fl else list(reversed(vs)), mi=CON, tile=WT, axes=(0, 2))
    else:
        tbox(TI, -L2, TF, TO, L2, TC)
    # end faces of the slabs / walls (the cut concrete ring) so a lone section reads solid
    for x0, z0, x1, z1 in ((-TO, TB, TO, TF), (-TO, TC, TO, TR), (-TO, TF, -TI, TC), (TI, TF, TO, TC)):
        for y in (-L2, L2):
            quad(bm, uv, [(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)] if y < 0 else [(x1, y, z0), (x0, y, z0), (x0, y, z1), (x1, y, z1)], mi=CON, tile=WT, axes=(0, 2))
    # faint joint lines at both ends (adjacent sections give one 4 cm mortar joint)
    for ya, yb in ((-L2, -L2 + 0.02), (L2 - 0.02, L2)):
        box(bm, uv, -TI, ya, TF, TI, yb, TF + 0.002, mi=JOINT, skip=('front', 'back'))
        box(bm, uv, -TI, ya, TC - 0.002, TI, yb, TC, mi=JOINT, skip=('front', 'back'))
        for sx in (-1, 1):
            box(bm, uv, sx * TI - (0.002 if sx > 0 else 0), ya, TF, sx * TI + (0.002 if sx < 0 else 0), yb, TC, mi=JOINT, skip=('front', 'back'))
    # cable trays on both walls at z -1.40 / -2.00: perforated galv ladder tray |x| 0.70 .. 0.98 on cantilever arms
    TRAY_CABLES = [  # (|x|, mat, r, z above the tray bottom): two layers, black / yellow / grey
        (0.735, CBK, 0.026, 0.026), (0.785, CYL, 0.022, 0.022), (0.83, CBK, 0.024, 0.024), (0.875, CGR, 0.02, 0.02), (0.915, CBK, 0.022, 0.022),
        (0.952, CYL, 0.016, 0.016), (0.76, CGR, 0.018, 0.064), (0.805, CBK, 0.02, 0.062), (0.85, CYL, 0.016, 0.058), (0.895, CBK, 0.02, 0.058),
        (0.935, CGR, 0.015, 0.048)]
    for sx in (-1, 1):
        YR = [(-L2, -1.05), (1.05, L2)] if (tee and sx > 0) else [(-L2, L2)]
        for zt in (-1.40, -2.00):
          for ya_, yb_ in YR:
            def X(a, b):
                return (min(sx * a, sx * b), max(sx * a, sx * b))
            xa, xb = X(0.70, 0.98)
            box(bm, uv, xa, ya_, zt - 0.006, xb, yb_, zt, mi=GALV, skip=('front', 'back'))
            for a, b in ((0.70, 0.706), (0.974, 0.98)):
                xa, xb = X(a, b)
                box(bm, uv, xa, ya_, zt - 0.006, xb, yb_, zt + 0.045, mi=GALV, skip=('front', 'back'))
            for y in [y for y in (-1.5, -0.5, 0.5, 1.5) if ya_ < y < yb_]:
                xa, xb = X(0.69, TI)
                box(bm, uv, xa, y - 0.02, zt - 0.045, xb, y + 0.02, zt - 0.006, mi=GALV)
                xa, xb = X(0.975, TI)
                box(bm, uv, xa, y - 0.022, zt - 0.20, xb, y + 0.022, zt + 0.08, mi=GALV)
            xa, xb = X(0.70, 0.98)
            cbox(cb, xa, ya_, zt - 0.045, xb, yb_, zt + 0.06, 1)
            for tc in TRAY_CABLES:
                x, mi, r = tc[:3]
                z = zt + tc[3]
                cyl(bm, uv, (sx * x, ya_, z), (sx * x, yb_, z), r, sides=8, mi=mi, vrep=(yb_ - ya_) * 2, caps=tee and sx > 0)
    # tee: the +X tray cables turn up at the opening and cross above it just under the ceiling (all above z -0.9)
    if tee:
        k = 0
        for zt in (-1.40, -2.00):
            for tc in TRAY_CABLES:
                x, mi, r = tc[:3]
                z = zt + tc[3]
                xo = 0.72 + (k % 11) * 0.025
                zo = -0.835 if k < 11 else -0.868
                for sy in (-1, 1):
                    cable(bm, uv, [(x, sy * 1.06, z), (x, sy * 1.03, z + 0.04), (xo, sy * 1.03, zo - 0.04), (xo, sy * 1.0, zo)], min(r, 0.016), mi)
                cyl(bm, uv, (xo, -1.0, zo), (xo, 1.0, zo), min(r, 0.016), sides=8, mi=mi, vrep=4, caps=False)
                k += 1
        for y in (-0.6, 0.0, 0.6):                                                           # ceiling hangers + support bars
            box(bm, uv, 0.70, y - 0.02, -0.895, 0.99, y + 0.02, -0.887, mi=GALV)
            for x in (0.71, 0.98):
                box(bm, uv, x - 0.005, y - 0.005, -0.895, x + 0.005, y + 0.005, TC, mi=GALV)
    # ceiling LED battens centred y -1.0 / +1.0 (x 0), diffuser emissive; conduit along the ceiling
    for yc in (-1.0, 1.0):
        box(bm, uv, -0.045, yc - 0.6, TC - 0.05, 0.045, yc + 0.6, TC, mi=LAMP)
        box(bm, uv, -0.035, yc - 0.58, TC - 0.065, 0.035, yc + 0.58, TC - 0.05, mi=GLOW)
    cyl(bm, uv, (0.15, -L2, TC - 0.015), (0.15, L2, TC - 0.015), 0.012, sides=8, mi=GALV, vrep=4, caps=False)
    for y in (-1.5, -0.5, 0.5, 1.5):
        box(bm, uv, 0.13, y - 0.012, TC - 0.03, 0.17, y + 0.012, TC, mi=GALV)
    for yc in (-1.0, 1.0):
        cable(bm, uv, [(0.15, yc + 0.62, TC - 0.015), (0.045, yc + 0.62, TC - 0.03)], 0.008, GALV, sides=6)
    # pipes along the -X floor edge, saddles every 2 m
    for x, z, r, mi in ((-0.90, TF + 0.06, 0.06, BLK), (-0.76, TF + 0.05, 0.05, CGR), (-0.88, TF + 0.17, 0.045, DUCT)):
        cyl(bm, uv, (x, -L2, z), (x, L2, z), r, sides=14, mi=mi, vrep=4, caps=False)
    for y in (-1.0, 1.0):
        box(bm, uv, -TI, y - 0.03, TF, -0.69, y + 0.03, TF + 0.015, mi=GALV)
        box(bm, uv, -0.71, y - 0.03, TF, -0.69, y + 0.03, TF + 0.24, mi=GALV)
    cbox(cb, -TI, -L2, TF, -0.70, L2, TF + 0.22, 1)
    add(finish(name, bm, [mat('opslabs_ug_wall'), mat('opslabs_ug_floor'), mat('opslabs_ug_galv'), mat('opslabs_ug_cable_black'),
                                         mat('opslabs_ug_cable_yellow'), mat('opslabs_ug_cable_grey'), mat('opslabs_ug_black'), mat('opslabs_ug_lampbody'),
                                         mat('opslabs_ug_glow_cool', 'emissive.sps'), mat('opslabs_ug_wall'), mat('opslabs_ug_wall'), mat('opslabs_ug_joint'),
                                         mat('opslabs_ug_duct'), mat('opslabs_ug_wall')]), colmesh(name, cb))


build_tunnel('opslabs_ug_tunnel')
build_tunnel('opslabs_ug_tunnel_tee', tee=True)

# ================================================================ 4. tunnel end wall (origin at the y = 0 face)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()
box(bm, uv, -1.2, 0.0, -3.05, 1.2, 0.20, -0.55, mi=0, tile=WT)
cbox(cb, -1.2, 0.0, -3.05, 1.2, 0.20, -0.55, 0)
box(bm, uv, -0.42, -0.10, -2.48, 0.42, 0.0, -1.92, mi=0, tile=1.0, skip=('back',))   # duct entry boss
cbox(cb, -0.42, -0.10, -2.48, 0.42, 0.0, -1.92, 0)
for x in (-0.25, 0.0, 0.25):
    cyl(bm, uv, (x, -0.10, -2.20), (x, -0.105, -2.20), 0.075, sides=16, mi=3)          # sealant ring
    cyl(bm, uv, (x, -0.105, -2.20), (x, -0.20, -2.20), 0.055, sides=16, mi=1)          # duct stub
    cyl(bm, uv, (x, -0.19, -2.20), (x, -0.235, -2.20), 0.062, 0.058, sides=16, mi=2)   # red end cap
cbox(cb, -0.32, -0.235, -2.27, 0.32, -0.10, -2.13, 1)
add(finish('opslabs_ug_tunnel_end', bm, [mat('opslabs_ug_wall'), mat('opslabs_ug_duct'), mat('opslabs_ug_red'), mat('opslabs_ug_black')]),
    colmesh('opslabs_ug_tunnel_end', cb))

# ================================================================ 5/6. duct risers (origin = pipe centre at ground level)
c = Canvas(32, 256, (26, 26, 28)); c.rect(6, 0, 9, 256, (120, 122, 124)); c.rect(22, 0, 25, 256, (120, 122, 124)); c.noise(3); save(c, 'opslabs_ug_hdpe')
c = Canvas(64, 64, (158, 156, 150)); c.noise(14); save(c, 'opslabs_ug_collar')
RR = 0.055                           # duct radius (d 0.11)


def riser_common(bm, uv, top):
    cyl(bm, uv, (0, 0, -0.85), (0, 0, top), RR, sides=16, mi=0, vrep=(top + 0.85) * 3)                # duct
    cyl(bm, uv, (0, 0, -0.85), (0, 0, -0.80), RR + 0.012, sides=16, mi=0)                          # bell end
    cyl(bm, uv, (0, 0, -0.82), (0, 0, -0.805), 0.10, sides=16, mi=2)                               # ceiling flange
    for a in range(4):
        x, y = 0.08 * math.cos(a * math.pi / 2 + 0.6), 0.08 * math.sin(a * math.pi / 2 + 0.6)
        cyl(bm, uv, (x, y, -0.805), (x, y, -0.80), 0.008, sides=6, mi=2)                          # flange bolts
    cyl(bm, uv, (0, 0, -0.02), (0, 0, 0.06), 0.15, sides=20, mi=1)                                 # concrete collar d 0.3
    cyl(bm, uv, (0, 0, 0.06), (0, 0, 0.07), 0.15, 0.13, sides=20, mi=1)                            # weathered top


# goose-neck riser: vertical to +0.90, 90 deg bend (R 0.15) facing -Y, cap + cable gland at y -0.22, z 1.05
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()
riser_common(bm, uv, 0.90)
BR = 0.15
arc = [(0, -BR + BR * math.cos(math.radians(a)), 0.90 + BR * math.sin(math.radians(a))) for a in range(0, 91, 10)]
cable(bm, uv, arc, RR, 0, sides=16)
cyl(bm, uv, (0, -BR, 0.90 + BR), (0, -BR - 0.03, 0.90 + BR), RR, sides=16, mi=0)
cyl(bm, uv, (0, -BR - 0.03, 0.90 + BR), (0, -BR - 0.07, 0.90 + BR), RR + 0.008, sides=16, mi=3)    # cap
cyl(bm, uv, (0, -BR - 0.07, 0.90 + BR), (0, -BR - 0.095, 0.90 + BR), 0.02, 0.016, sides=10, mi=3)  # gland
cable(bm, uv, [(0, -BR - 0.09, 0.90 + BR), (0, -0.30, 1.04), (0, -0.33, 0.98), (0.02, -0.33, 0.85)], 0.008, 4, sides=6)  # cable stub
cbox(cb, -0.15, -0.15, -0.02, 0.15, 0.15, 0.07, 0)
cbox(cb, -RR, -RR, 0.07, RR, RR, 0.95, 3)
cbox(cb, -RR - 0.008, -0.24, 0.90, RR + 0.008, RR, 0.90 + BR + RR + 0.008, 3)
RMATS = lambda: [mat('opslabs_ug_hdpe'), mat('opslabs_ug_collar'), mat('opslabs_ug_galv'), mat('opslabs_ug_black'), mat('opslabs_ug_cable_black')]
add(finish('opslabs_ug_riser', bm, RMATS()), colmesh('opslabs_ug_riser', cb))
# flush riser: up to +0.05, flush duct cap + gland
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()
riser_common(bm, uv, 0.05)
cyl(bm, uv, (0, 0, 0.05), (0, 0, 0.075), RR + 0.008, sides=16, mi=3)                              # flush cap (top +0.075)
cyl(bm, uv, (0, 0, 0.075), (0, 0, 0.10), 0.02, 0.016, sides=10, mi=3)                             # gland
cable(bm, uv, [(0, 0, 0.095), (0, 0, 0.16), (0, -0.04, 0.21), (0, -0.12, 0.22)], 0.008, 4, sides=6)
cbox(cb, -0.15, -0.15, -0.02, 0.15, 0.15, 0.07, 0)
cbox(cb, -RR - 0.008, -RR - 0.008, 0.07, RR + 0.008, RR + 0.008, 0.10, 3)
add(finish('opslabs_ug_riser_flush', bm, RMATS()), colmesh('opslabs_ug_riser_flush', cb))

# ================================================================ 7. street access entrance (kiosk + stairwell)
c = Canvas(128, 128, (38, 66, 48)); c.noise(5)
for x in range(0, 128, 32):
    c.rect(x, 0, x + 1, 128, (30, 54, 40))                                                     # GRP panel seams
save(c, 'opslabs_ug_grp')
c = Canvas(128, 256, (118, 122, 126))
c.rect(0, 0, 128, 3, (80, 84, 88)); c.rect(0, 253, 128, 256, (80, 84, 88)); c.rect(0, 0, 3, 256, (80, 84, 88)); c.rect(125, 0, 128, 256, (80, 84, 88))
c.rect(10, 20, 118, 22, (96, 100, 104)); c.rect(10, 234, 118, 236, (96, 100, 104))
c.rect(14, 60, 114, 84, (244, 244, 240))                                                        # sign on the door
text(c, 'AUTHORISED', 64, 63, 1, (180, 20, 20)); text(c, 'ACCESS ONLY', 64, 74, 1, (20, 20, 20))
c.noise(4); save(c, 'opslabs_ug_door')
c = Canvas(64, 64, (40, 66, 50))
for y in range(4, 64, 8):
    c.rect(4, y, 60, y + 4, (14, 22, 18)); c.rect(4, y + 4, 60, y + 5, (64, 96, 76))
save(c, 'opslabs_ug_vent')
c = Canvas(64, 96, (40, 40, 42))
c.rect(8, 8, 56, 26, (60, 120, 90))
for r in range(4):
    for k in range(3):
        c.rect(10 + k * 16, 34 + r * 15, 22 + k * 16, 45 + r * 15, (190, 190, 194))
c.noise(2); save(c, 'opslabs_ug_keypad')
c = Canvas(256, 64, (244, 244, 240))
c.rect(0, 0, 256, 4, (180, 20, 20)); c.rect(0, 60, 256, 64, (180, 20, 20))
text(c, 'AUTHORISED', 128, 10, 3, (180, 20, 20)); text(c, 'ACCESS ONLY', 128, 36, 3, (20, 20, 20))
save(c, 'opslabs_ug_authsign')

bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0'); cb = bmesh.new()
# indices: 0 wall 1 floor 2 galv 3 grp 4 door 5 vent 6 keypad 7 authsign 8 lampbody 9 glow 10 black
EW, EF, EG, EGRP, EDOOR, EVENT, EKEY, ESIGN, ELAMP, EGLOW, EBLK = range(11)


def ebox(x0, y0, z0, x1, y1, z1, mi=EW, colm=0, tile=WT, col=True):
    box(bm, uv, x0, y0, z0, x1, y1, z1, mi=mi, tile=tile)
    if col:
        cbox(cb, x0, y0, z0, x1, y1, z1, colm)


# --- stairwell shell (as the chamber): floor, solid walls, one 2.0 x 2.2 opening in +Y
ebox(-OO, -OO, FB, OO, OO, FT, mi=EF)
ebox(-OO, -OO, FT, OO, -OI, RB)                                                                  # -Y wall
ebox(-OO, OI, FT, -OW, OO, RB); ebox(OW, OI, FT, OO, OO, RB); ebox(-OW, OI, OT, OW, OO, RB)      # +Y wall with the opening
ebox(-OO, -OI, FT, -OI, OI, RB); ebox(OI, -OI, FT, OO, OI, RB)                                   # -X / +X walls
# roof with the stair opening x -1.4 .. -0.4, y -1.6 .. -0.3
SO = (-1.4, -1.6, -0.4, -0.3)
ebox(-OO, -OO, RB, SO[0], OO, RT); ebox(SO[2], -OO, RB, OO, OO, RT)
ebox(SO[0], -OO, RB, SO[2], SO[1], RT); ebox(SO[0], SO[3], RB, SO[2], OO, RT)
# --- stair flight: 14 risers of 0.193, goings of 0.15, x -1.4 .. -0.4; top landing z -0.30 at y -1.6 .. -1.35,
#     bottom step meets the floor at y +0.60
NR, SG = 14, 0.15
SR = (-0.30 - FT) / NR
for k in range(1, NR + 1):
    y1 = 0.6 - (k - 1) * SG
    y0 = 0.6 - k * SG if k < NR else -OI
    ebox(-1.4, y0, FT, -0.4, y1, FT + k * SR, mi=EW, tile=1.0)
    box(bm, uv, -1.4, y1 - 0.03, FT + k * SR - 0.002, -0.4, y1 - 0.004, FT + k * SR + 0.001, mi=EBLK)  # anti-slip nosing
# handrails: posts on the open side (x -0.40), rail 0.9 above the nosings; wall rail on the -X wall; both stop under the slab
for k in (1, 5, 9, 12):
    yp = 0.6 - (k - 0.5) * SG
    cyl(bm, uv, (-0.42, yp, FT + k * SR), (-0.42, yp, FT + k * SR + 0.9), 0.02, sides=8, mi=EG)
RAIL = lambda y: FT + 0.9 + (0.6 - y) / SG * SR
cable(bm, uv, [(-0.42, 0.6, RAIL(0.6)), (-0.42, -0.95, RAIL(-0.95))], 0.022, EG)
cable(bm, uv, [(-0.42, 0.6, RAIL(0.6)), (-0.42, 0.75, RAIL(0.6) - 0.05), (-0.42, 0.75, RAIL(0.6) - 0.9)], 0.022, EG)
for yb in (0.45, -0.35):
    cyl(bm, uv, (-OI, yb, RAIL(yb)), (-1.52, yb, RAIL(yb)), 0.01, sides=6, mi=EG)
cable(bm, uv, [(-1.52, 0.7, RAIL(0.6)), (-1.52, -0.45, RAIL(-0.45))], 0.02, EG)
# bulkhead lamp at (0.6, 0.6) under the ceiling, emissive lens (as the chamber)
box(bm, uv, 0.44, 0.5, RB - 0.06, 0.76, 0.7, RB, mi=ELAMP)
box(bm, uv, 0.47, 0.525, -0.395, 0.73, 0.675, RB - 0.06, mi=EGLOW)
# --- kiosk: 2.0 x 2.0, 2.4 tall dark green GRP on a concrete plinth, shallow roof, steel door on -Y
KZ = 0.05
# plinth / floor (opening over the stairs inside the kiosk, x -0.95 .. -0.4, y -0.95 .. -0.3)
ebox(-1.05, -1.05, 0.0, 1.05, -0.95, KZ, mi=EW, tile=1.0); ebox(-1.05, -0.3, 0.0, 1.05, 1.05, KZ, mi=EW, tile=1.0)
ebox(-1.05, -0.95, 0.0, -0.95, -0.3, KZ, mi=EW, tile=1.0); ebox(-0.4, -0.95, 0.0, 1.05, -0.3, KZ, mi=EW, tile=1.0)
# the part of the roof opening outside the kiosk is closed by a cover slab at road level
ebox(SO[0], SO[1], RT, -0.95, SO[3], -0.01, mi=EW); ebox(-0.95, SO[1], RT, SO[2], -0.95, -0.01, mi=EW)
T = 0.05
ebox(-1.0, -1.0, KZ, -0.45, -1.0 + T, 2.4, mi=EGRP, colm=3, tile=2.0); ebox(0.45, -1.0, KZ, 1.0, -1.0 + T, 2.4, mi=EGRP, colm=3, tile=2.0)
ebox(-0.45, -1.0, 2.05, 0.45, -1.0 + T, 2.4, mi=EGRP, colm=3, tile=2.0)                          # over the door
ebox(-1.0, 1.0 - T, KZ, 1.0, 1.0, 2.4, mi=EGRP, colm=3, tile=2.0)
ebox(-1.0, -1.0 + T, KZ, -1.0 + T, 1.0 - T, 2.4, mi=EGRP, colm=3, tile=2.0); ebox(1.0 - T, -1.0 + T, KZ, 1.0, 1.0 - T, 2.4, mi=EGRP, colm=3, tile=2.0)
ebox(-1.08, -1.08, 2.4, 1.08, 1.08, 2.46, mi=EGRP, colm=3, tile=2.0)                             # roof
ebox(-0.9, -0.9, 2.46, 0.9, 0.9, 2.50, mi=EGRP, colm=3, tile=2.0)                                # shallow raised top
box(bm, uv, -1.0, -1.01, 0.0, 1.0, 1.01, KZ + 0.05, mi=EGRP, tile=2.0)                           # kick strip
# steel door (closed): x -0.45 .. 0.45, z 0.05 .. 2.05, face at y -0.99; frame; handle; keypad on the right
box(bm, uv, -0.45, -0.99, KZ, 0.45, -0.97, 2.05, mi=EDOOR, fmi={'top': EG, 'bottom': EG, 'left': EG, 'right': EG, 'back': EG})
cbox(cb, -0.45, -1.0, KZ, 0.45, -0.95, 2.05, 1)
for b in ((-0.5, -0.45, KZ, 2.1), (0.45, 0.5, KZ, 2.1)):
    box(bm, uv, b[0], -1.015, b[2], b[1], -0.99, b[3], mi=EG)
box(bm, uv, -0.45, -1.015, 2.05, 0.45, -0.99, 2.1, mi=EG)
cable(bm, uv, [(0.33, -0.99, 1.05), (0.33, -1.04, 1.05), (0.20, -1.04, 1.05)], 0.012, EG, sides=8)  # lever handle
box(bm, uv, 0.30, -1.0, 0.98, 0.36, -0.985, 1.12, mi=EG)
box(bm, uv, 0.58, -1.03, 1.20, 0.72, -1.0, 1.41, mi=EKEY, fmi={'top': EBLK, 'bottom': EBLK, 'left': EBLK, 'right': EBLK, 'back': EBLK})
box(bm, uv, -0.90, -1.012, 1.55, -0.55, -1.0, 1.70, mi=ESIGN, fmi={'top': EG, 'bottom': EG, 'left': EG, 'right': EG, 'back': EG})  # sign
box(bm, uv, -0.85, -1.015, 1.85, -0.55, -1.0, 2.15, mi=EVENT, fmi={'top': EGRP, 'bottom': EGRP, 'left': EGRP, 'right': EGRP, 'back': EGRP})  # vent
box(bm, uv, 1.0, -0.25, 1.85, 1.015, 0.25, 2.15, mi=EVENT)                                      # side vent
add(finish('opslabs_ug_entrance', bm, [mat('opslabs_ug_wall'), mat('opslabs_ug_floor'), mat('opslabs_ug_galv'), mat('opslabs_ug_grp'), mat('opslabs_ug_door'),
                                       mat('opslabs_ug_vent'), mat('opslabs_ug_keypad'), mat('opslabs_ug_authsign'), mat('opslabs_ug_lampbody'),
                                       mat('opslabs_ug_glow_warm', 'emissive.sps'), mat('opslabs_ug_black')]), colmesh('opslabs_ug_entrance', cb))

# ---------------------------------------------------------------- drawables, collision, ytyp, export
scene = bpy.context.scene
scene.create_seperate_drawables = True
drawables = []
for obj, colme in models:
    scene.auto_create_embedded_col = True
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.sollumz.converttodrawable()
    d = obj.parent
    drawables.append(d)
    n = 0
    for child in d.children_recursive:
        if child.type == 'MESH' and 'poly_mesh' in child.name:
            old = child.data
            child.data = colme                                                         # structural collision only
            colme.name = old.name
            bpy.data.meshes.remove(old)
            n += 1
    print('COLLISION', d.name, n, len(colme.polygons))
bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = YTYP_NAME
bpy.ops.object.select_all(action='DESELECT')
for d in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0]
bpy.ops.sollumz.createarchetypefromselected()
for a in ytyp.archetypes:
    a.lod_dist = LOD
print('ARCHETYPES', len(ytyp.archetypes))
res = bpy.ops.sollumz.export_assets(directory=OUT, direct_export=True, use_custom_settings=True,
                                    target_formats={'CWXML'}, target_versions={'GEN8'}, limit_to_selected=False, export_ytyps=True)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_underground.blend'))
