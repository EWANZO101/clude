"""Telecom / fibre props (generic, no operator branding):
  fibre cable segments (black outdoor dropwire, yellow indoor patch), joints
  telegraph poles 7 / 10 / 13 m with ring head, steps and ID plate
  CBT (connectorised block terminal), copper DP, splice enclosure
  green street cabinets (PCP + FTTC extension), carriageway cover
  customer splice point (CSP), optical network terminal (ONT)
blender -b --python build_telecom.py -- <out_dir>
Wall/pole-mounted props have their origin on the BACK face (they sit on the surface you aim at)
and face -Y; floor props have their origin at the bottom centre.
"""
import math
import os
import sys

import bmesh
import bpy

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

FONT = {
    'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'], 'P': ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
    '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'], '9': ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
    '0': ['01110', '10011', '10101', '10101', '11001', '10001', '01110'], '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
    '3': ['11110', '00001', '00001', '01110', '00001', '00001', '11110'], 'M': ['10001', '11011', '10101', '10101', '10001', '10001', '10001'],
    'F': ['11111', '10000', '10000', '11110', '10000', '10000', '10000'], 'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'],
    'B': ['11110', '10001', '10001', '11110', '10001', '10001', '11110'], 'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'], '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
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


# ---------------------------------------------------------------------------
# textures
# ---------------------------------------------------------------------------

def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


# fibre jackets
c = Canvas(16, 256, (18, 18, 19)); c.noise(2); save(c, 'opslabs_fibre_black')
c = Canvas(16, 256, (232, 196, 30))
for y in range(0, 256, 64):
    c.rect(6, y + 10, 10, y + 40, (190, 158, 20))
c.noise(2); save(c, 'opslabs_fibre_yellow')

# fibre boxes: cardboard, coloured bands, "FIBRE" + length in block letters
for colour, band, ink, length in (('black', (28, 28, 30), (28, 28, 30), '1000M'), ('yellow', (225, 185, 25), (40, 34, 20), '500M')):
    c = Canvas(256, 256, (178, 140, 96)); c.noise(6)
    c.rect(0, 0, 256, 34, band); c.rect(0, 222, 256, 256, band)
    text(c, 'FIBRE', 38, 66, 6, ink)
    text(c, length, 38 if len(length) == 5 else 56, 136, 6, ink)
    c.rect(38, 196, 218, 202, band)
    save(c, 'opslabs_fibre_box_' + colour)

# creosoted wood (vertical grain, darker knots)
import random
rnd = random.Random(11)
c = Canvas(128, 512, (96, 70, 44))
for x in range(128):
    shade = rnd.randint(-14, 10)
    c.rect(x, 0, x + 1, 512, (96 + shade, 70 + shade, 44 + shade // 2))
for _ in range(14):
    kx, ky = rnd.randint(8, 120), rnd.randint(10, 500)
    c.circle(kx, ky, rnd.randint(2, 5), (52, 36, 22), 0.85)
c.noise(5); save(c, 'opslabs_pole_wood')

# galvanised steel (ring head, steps, brackets)
c = Canvas(64, 64, (150, 154, 158)); c.noise(10); save(c, 'opslabs_galv')

# pole ID plate: black on white "DP 19"
c = Canvas(128, 64, (238, 238, 232))
c.rect(0, 0, 128, 4, (30, 30, 30)); c.rect(0, 60, 128, 64, (30, 30, 30))
text(c, 'DP', 14, 14, 5, (20, 20, 20)); text(c, '19', 76, 14, 5, (20, 20, 20))
save(c, 'opslabs_pole_plate')

# black weatherproof plastic (CBT, splice enclosure) with moulded ribs
c = Canvas(64, 128, (26, 27, 28))
for y in range(0, 128, 16):
    c.rect(0, y, 64, y + 2, (40, 41, 43))
c.noise(3); save(c, 'opslabs_black_plastic')

# CBT front: 12 numbered ports (green dust caps), 256 x 128
c = Canvas(256, 128, (26, 27, 28))
for row in range(3):
    for col in range(4):
        x, y = 30 + col * 54, 14 + row * 38
        c.circle(x + 14, y + 14, 14, (14, 14, 15))
        c.circle(x + 14, y + 14, 10, (40, 150, 70))
        c.circle(x + 14, y + 14, 4, (24, 90, 40))
c.noise(3); save(c, 'opslabs_cbt_front')

# green dust caps on the CBT ports
c = Canvas(16, 16, (40, 150, 70)); c.noise(3); save(c, 'opslabs_port_cap')

# grey plastic (copper DP, CSP)
c = Canvas(64, 64, (128, 131, 133)); c.noise(4); save(c, 'opslabs_grey_plastic')
c = Canvas(128, 128, (128, 131, 133))
c.rect(10, 10, 118, 118, (118, 121, 123)); c.rect(14, 14, 114, 16, (150, 152, 154))
c.circle(64, 100, 6, (90, 92, 94)); c.noise(4); save(c, 'opslabs_grey_lid')

# street cabinet green with door seams, louvres and lock
c = Canvas(256, 256, (40, 78, 52))
c.rect(126, 0, 130, 256, (24, 46, 30))                       # double door seam
for y in range(40, 90, 8):
    c.rect(30, y, 100, y + 4, (28, 54, 36)); c.rect(156, y, 226, y + 4, (28, 54, 36))
c.rrect(108, 120, 120, 150, 3, (180, 180, 170)); c.rrect(136, 120, 148, 150, 3, (180, 180, 170))  # locks
c.rect(0, 240, 256, 256, (30, 58, 38))
c.noise(4); save(c, 'opslabs_cabinet_green')
c = Canvas(64, 64, (40, 78, 52)); c.noise(4); save(c, 'opslabs_cabinet_plain')

# carriageway cover: cast iron tread pattern
c = Canvas(128, 128, (70, 72, 74))
for y in range(4, 128, 12):
    for x in range(4 + (y // 12 % 2) * 6, 128, 12):
        c.rrect(x, y, x + 8, y + 3, 1, (100, 102, 104))
c.rect(0, 0, 128, 3, (40, 40, 42)); c.rect(0, 125, 128, 128, (40, 40, 42))
c.rect(0, 0, 3, 128, (40, 40, 42)); c.rect(125, 0, 128, 128, (40, 40, 42))
c.noise(6); save(c, 'opslabs_cover_iron')

# ONT: white with status LEDs (PON / LOS / LAN / PWR)
c = Canvas(128, 64, (240, 241, 239))
for i, col in enumerate(((60, 220, 90), (60, 220, 90), (60, 220, 90), (60, 220, 90))):
    c.circle(26 + i * 26, 46, 3, col)
c.rect(0, 0, 128, 3, (220, 222, 220)); c.noise(2); save(c, 'opslabs_ont_front')
c = Canvas(64, 64, (240, 241, 239)); c.noise(2); save(c, 'opslabs_white_plastic')

# ---------------------------------------------------------------------------
# materials + helpers
# ---------------------------------------------------------------------------

MATS = {}


def mat(name, shader='default.sps'):
    if name in MATS:
        return MATS[name]
    m = sz_mats.create_shader(shader)
    m.name = name
    img = bpy.data.images.load(os.path.join(TEX, name + '.dds'), check_existing=True)
    img.name = name
    for node in m.node_tree.nodes:
        if isinstance(node, bpy.types.ShaderNodeTexImage) and node.name == 'DiffuseSampler':
            node.image = img
            node.texture_properties.embedded = True
    MATS[name] = m
    return m


for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def finish(name, bm, mats, smooth=False):
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


def frustum(bm, uv, axis, r0, r1, length, start=0.0, sides=16, mi=0, v_rep=1.0, caps=True, center=(0.0, 0.0)):
    """tapered cylinder along +Y ('y') or +Z ('z')"""
    rings = []
    for k, (r, t) in enumerate(((r0, start), (r1, start + length))):
        ring = []
        for i in range(sides):
            a = 2 * math.pi * i / sides
            p, q = r * math.cos(a), r * math.sin(a)
            if axis == 'z':
                ring.append(bm.verts.new((center[0] + p, center[1] + q, t)))
            else:
                ring.append(bm.verts.new((center[0] + p, t, center[1] + q)))
        rings.append(ring)
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]) if axis == 'z' else (rings[0][j], rings[0][i], rings[1][i], rings[1][j]))
        f.material_index = mi
        f.smooth = True
        us = (i / sides, (i + 1) / sides)
        uvs = ((us[0], 0), (us[1], 0), (us[1], v_rep), (us[0], v_rep)) if axis == 'z' else ((us[1], 0), (us[0], 0), (us[0], v_rep), (us[1], v_rep))
        for loop, u in zip(f.loops, uvs):
            loop[uv].uv = u
    if caps:
        for k, ring in enumerate(rings):
            r = ring if (k == 1) == (axis == 'z') else list(reversed(ring))
            f = bm.faces.new(r)
            f.material_index = mi
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.02)
    return rings


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, full=True, front_mi=None):
    faces = {
        'y0': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'y1': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'x0': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'x1': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'z1': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'z0': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    for k, vs in faces.items():
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = front_mi if (front_mi is not None and k == 'y0') else mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


models = []   # (obj, lod, collision or None)


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- fibre cable: black outdoor dropwire Ø5 mm, yellow indoor patch Ø3 mm
for colour, radius in (('black', 0.0025), ('yellow', 0.0015)):
    for cm in (5, 10, 25, 50, 100, 200):
        bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
        frustum(bm, uv, 'y', radius, radius, cm / 100, sides=8, v_rep=cm / 100 * 4)
        add(finish(f'opslabs_fibre_{colour}_{cm:03d}', bm, [mat('opslabs_fibre_' + colour)], True), 30.0)
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=radius * 1.02)
    for f in bm.faces:
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.05)
    add(finish(f'opslabs_fibre_{colour}_joint', bm, [mat('opslabs_fibre_' + colour)], True), 30.0)

# --- fibre boxes (reel inside, cable end out of a dispensing hole in the lid), origin bottom centre
for colour, radius, half, H in (('black', 0.0025, 0.20, 0.25), ('yellow', 0.0015, 0.16, 0.20)):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -half, -half, 0.0, half, half, H, mi=0)
    hy = -half * 0.55
    hole = bmesh.ops.create_circle(bm, cap_ends=True, segments=12, radius=0.014)
    for v in hole['verts']:
        v.co = (v.co.x, v.co.y + hy, H + 0.0004)
    for f in {f for v in hole['verts'] for f in v.link_faces}:
        f.material_index = 2
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    frustum(bm, uv, 'z', radius, radius, 0.07, start=H, sides=8, mi=1, v_rep=0.3, center=(0.0, hy))
    add(finish(f'opslabs_fibre_box_{colour}', bm, [mat('opslabs_fibre_box_' + colour), mat('opslabs_fibre_' + colour), mat('opslabs_black_plastic')]), 60.0, 'CARDBOARD')

# --- telegraph poles (Ø ~230 mm butt → ~150 mm top), ring head 200 mm from the top, steps, ID plate
for H in (7, 10, 13):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    rb, rt = 0.115 + H * 0.002, 0.075
    frustum(bm, uv, 'z', rb, rt, H, sides=16, mi=0, v_rep=H / 2.0)
    # ring head: steel band 200 mm below the top
    rr = rt + (rb - rt) * (0.2 / H) + 0.006
    frustum(bm, uv, 'z', rr, rr, 0.06, start=H - 0.23, sides=16, mi=1, v_rep=0.2)
    # pole steps: alternating sides from 2.4 m up to 1 m below the top, every 0.4 m
    z, side = 2.4, 1
    while z < H - 1.0:
        rz = rb + (rt - rb) * (z / H)
        start = rz - 0.01
        steps = frustum(bm, uv, 'y', 0.009, 0.009, 0.16, start=start, sides=6, mi=1, v_rep=0.2, center=(0.0, z))
        if side < 0:
            for ring in steps:
                for v in ring:
                    v.co.y = -v.co.y
        z += 0.4
        side = -side
    # ID plate at 1.8 m facing -Y
    r18 = rb + (rt - rb) * (1.8 / H)
    box(bm, uv, -0.06, -r18 - 0.004, 1.75, 0.06, -r18 + 0.01, 1.81, mi=2, front_mi=2)
    add(finish(f'opslabs_pole_{H:02d}m', bm, [mat('opslabs_pole_wood'), mat('opslabs_galv'), mat('opslabs_pole_plate')], True), 300.0, 'WOOD_SOLID_MEDIUM')

# ---------------------------------------------------------------------------
# pole-mounted kit. Origin = the pole surface behind the item (y = 0), front faces -Y,
# z = 0 at the bottom of the bracket. No collision (they sit on a pole people climb).
# ---------------------------------------------------------------------------

def cyl(bm, uv, p0, p1, r, sides=10, mi=0, caps=True):
    """cylinder between two points"""
    import mathutils
    a, b = mathutils.Vector(p0), mathutils.Vector(p1)
    d = (b - a)
    L = d.length
    d.normalize()
    t = mathutils.Vector((1, 0, 0)) if abs(d.x) < 0.9 else mathutils.Vector((0, 1, 0))
    u = d.cross(t).normalized()
    w = d.cross(u).normalized()
    rings = []
    for c in (a, b):
        rings.append([bm.verts.new(c + (u * math.cos(2 * math.pi * i / sides) + w * math.sin(2 * math.pi * i / sides)) * r) for i in range(sides)])
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
        f.material_index = mi
        f.smooth = True
        for loop, uvv in zip(f.loops, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, 1), (i / sides, 1))):
            loop[uv].uv = uvv
    if caps:
        for k, ring in enumerate(rings):
            f = bm.faces.new(ring if k else list(reversed(ring)))
            f.material_index = mi
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.5)
    return rings


def dome(bm, uv, cx, cy, z0, r, h, mi=0, sides=16, steps=4):
    """rounded cap on top of a vertical cylinder of radius r at height z0"""
    prev = None
    for k in range(steps + 1):
        t = k / steps
        rr = r * math.cos(t * math.pi / 2)
        zz = z0 + h * math.sin(t * math.pi / 2)
        if k == steps:
            top = bm.verts.new((cx, cy, zz))
            for i in range(sides):
                f = bm.faces.new((prev[i], prev[(i + 1) % sides], top))
                f.material_index = mi
                f.smooth = True
                for loop in f.loops:
                    loop[uv].uv = (0.5, 0.95)
            break
        ring = [bm.verts.new((cx + rr * math.cos(2 * math.pi * i / sides), cy + rr * math.sin(2 * math.pi * i / sides), zz)) for i in range(sides)]
        if prev:
            for i in range(sides):
                j = (i + 1) % sides
                f = bm.faces.new((prev[i], prev[j], ring[j], ring[i]))
                f.material_index = mi
                f.smooth = True
                for loop, uvv in zip(f.loops, ((i / sides, t), (j / sides, t), (j / sides, t), (i / sides, t))):
                    loop[uv].uv = uvv
        prev = ring


def saddle(bm, uv, z0, z1, w=0.05, mi=1):
    """galvanised mounting plate, slightly curved to sit on the pole, plus a stand-off arm"""
    box(bm, uv, -w / 2, -0.006, z0, w / 2, 0.0, z1, mi=mi)
    for x in (-w / 2, w / 2 - 0.004):
        box(bm, uv, x, -0.004, z0, x + 0.004, 0.006, z1, mi=mi)      # curved edges wrapping the pole


# --- CBT (connectorised block terminal): black dome-top cylinder Ø150 on a stand-off bracket,
#     12 green-capped ports round the sloping base, cable gland underneath
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
saddle(bm, uv, 0.06, 0.30)
box(bm, uv, -0.018, -0.07, 0.10, 0.018, -0.006, 0.12, mi=1)          # lower arm
box(bm, uv, -0.018, -0.07, 0.24, 0.018, -0.006, 0.26, mi=1)          # upper arm
cy_ = -0.145
frustum(bm, uv, 'z', 0.075, 0.075, 0.20, start=0.14, sides=20, mi=0, v_rep=1.0, center=(0.0, cy_))   # body
dome(bm, uv, 0.0, cy_, 0.34, 0.075, 0.05, mi=0, sides=20)
frustum(bm, uv, 'z', 0.048, 0.075, 0.07, start=0.07, sides=20, mi=3, v_rep=0.3, center=(0.0, cy_), caps=False)  # sloping port ring
frustum(bm, uv, 'z', 0.048, 0.048, 0.01, start=0.06, sides=20, mi=3, v_rep=0.1, center=(0.0, cy_))
frustum(bm, uv, 'z', 0.077, 0.077, 0.012, start=0.14, sides=20, mi=3, v_rep=0.1, center=(0.0, cy_))     # grey seam band
for k in range(12):                                                   # ports pointing down and out
    a = 2 * math.pi * (k + 0.5) / 12
    ox, oy = math.cos(a), math.sin(a)
    p0 = (0.058 * ox, cy_ + 0.058 * oy, 0.105)
    p1 = (0.084 * ox, cy_ + 0.084 * oy, 0.078)
    cyl(bm, uv, p0, p1, 0.0075, sides=8, mi=4)
cyl(bm, uv, (0.0, cy_, 0.06), (0.0, cy_, 0.02), 0.013, sides=10, mi=0)  # cable gland
add(finish('opslabs_cbt', bm, [mat('opslabs_black_plastic'), mat('opslabs_galv'), mat('opslabs_cbt_front'), mat('opslabs_grey_plastic'), mat('opslabs_port_cap')], True), 120.0)

# --- copper DP: grey box 150 x 80 x 200 mm with a sloped rain lid, hinged front and three glands
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
saddle(bm, uv, 0.02, 0.24)
box(bm, uv, -0.075, -0.088, 0.04, 0.075, -0.008, 0.22, mi=0, front_mi=1)
sl = [(-0.081, -0.094, 0.22), (0.081, -0.094, 0.22), (0.081, -0.004, 0.245), (-0.081, -0.004, 0.245)]
quad_f = bm.faces.new([bm.verts.new(v) for v in sl]); quad_f.material_index = 0
for loop, uvv in zip(quad_f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
    loop[uv].uv = uvv
for x0 in (-0.081, 0.081):                                            # lid sides
    f = bm.faces.new([bm.verts.new(v) for v in ((x0, -0.094, 0.22), (x0, -0.004, 0.22), (x0, -0.004, 0.245))]); f.material_index = 0
    for loop in f.loops:
        loop[uv].uv = (0.5, 0.5)
f = bm.faces.new([bm.verts.new(v) for v in ((-0.081, -0.094, 0.215), (0.081, -0.094, 0.215), (0.081, -0.094, 0.222), (-0.081, -0.094, 0.222))]); f.material_index = 0
for loop in f.loops:
    loop[uv].uv = (0.5, 0.5)
box(bm, uv, -0.081, -0.094, 0.214, 0.081, -0.004, 0.22, mi=0)        # lid overhang
for x in (-0.04, 0.0, 0.04):
    cyl(bm, uv, (x, -0.05, 0.04), (x, -0.05, 0.012), 0.009, sides=8, mi=2)
box(bm, uv, 0.05, -0.091, 0.12, 0.062, -0.088, 0.15, mi=2)           # lock
add(finish('opslabs_copper_dp', bm, [mat('opslabs_grey_plastic'), mat('opslabs_grey_lid'), mat('opslabs_black_plastic')]), 100.0)

# --- splice enclosure ("man on the side"): vertical black dome closure Ø180 x 460 mm on two
#     brackets, clamp ring at the base, cable ports underneath
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
saddle(bm, uv, 0.04, 0.46)
for z in (0.10, 0.38):
    box(bm, uv, -0.02, -0.06, z, 0.02, -0.006, z + 0.025, mi=1)
cy_ = -0.155
frustum(bm, uv, 'z', 0.09, 0.09, 0.34, start=0.08, sides=22, mi=0, v_rep=2.0, center=(0.0, cy_))
dome(bm, uv, 0.0, cy_, 0.42, 0.09, 0.07, mi=0, sides=22)
for k in range(3):                                                    # moulded ribs
    frustum(bm, uv, 'z', 0.092, 0.092, 0.008, start=0.16 + k * 0.09, sides=22, mi=0, v_rep=0.1, center=(0.0, cy_))
frustum(bm, uv, 'z', 0.098, 0.098, 0.035, start=0.05, sides=22, mi=1, v_rep=0.2, center=(0.0, cy_))   # clamp ring
frustum(bm, uv, 'z', 0.085, 0.085, 0.03, start=0.02, sides=22, mi=2, v_rep=0.2, center=(0.0, cy_))    # base
for k in range(4):
    a = 2 * math.pi * k / 4 + 0.4
    cyl(bm, uv, (0.045 * math.cos(a), cy_ + 0.045 * math.sin(a), 0.02), (0.045 * math.cos(a), cy_ + 0.045 * math.sin(a), -0.02), 0.011, sides=8, mi=2)
add(finish('opslabs_splice_enclosure', bm, [mat('opslabs_black_plastic'), mat('opslabs_galv'), mat('opslabs_grey_plastic')], True), 100.0)

# --- stainless banding straps that go round the pole (one per radius, picked in game)
for rmm in range(75, 150, 5):
    R = rmm / 1000
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    frustum(bm, uv, 'z', R + 0.0015, R + 0.0015, 0.019, start=-0.0095, sides=20, mi=0, v_rep=0.05, caps=False)
    box(bm, uv, -0.012, -R - 0.009, -0.013, 0.012, -R + 0.001, 0.013, mi=0)   # buckle (front, -Y)
    add(finish(f'opslabs_pole_band_{rmm:03d}', bm, [mat('opslabs_galv')], True), 60.0)

# --- street cabinets (green): PCP 1100 x 450 x 1300 and FTTC extension 900 x 450 x 1250 with roof lip
for name, W, D, H in (('opslabs_cabinet_pcp', 1.10, 0.45, 1.30), ('opslabs_cabinet_fttc', 0.90, 0.45, 1.25)):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -W / 2, -D / 2, 0.0, W / 2, D / 2, H, mi=1, front_mi=0)
    box(bm, uv, -W / 2 - 0.02, -D / 2 - 0.03, H, W / 2 + 0.02, D / 2 + 0.03, H + 0.04, mi=1)   # roof lip
    box(bm, uv, -W / 2 + 0.02, -D / 2 + 0.02, -0.15, W / 2 - 0.02, D / 2 - 0.02, 0.0, mi=1)    # plinth (below ground)
    add(finish(name, bm, [mat('opslabs_cabinet_green'), mat('opslabs_cabinet_plain')]), 150.0, 'METAL_SOLID_MEDIUM')

# --- carriageway cover 600 x 450 x 20 mm frame (flush with the road), origin bottom
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.32, -0.245, 0.0, 0.32, 0.245, 0.012, mi=0)
add(finish('opslabs_carriageway_cover', bm, [mat('opslabs_cover_iron')]), 60.0, 'METAL_SOLID_SMALL')

# --- customer splice point: grey box 110 x 60 x 160 mm, origin back
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.055, -0.06, 0.0, 0.055, 0.0, 0.16, mi=0, front_mi=1)
add(finish('opslabs_csp', bm, [mat('opslabs_grey_plastic'), mat('opslabs_grey_lid')]), 50.0, 'PLASTIC')

# --- ONT: white box 160 x 35 x 110 mm on the wall, LEDs on the front, origin back
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.08, -0.035, 0.0, 0.08, 0.0, 0.11, mi=0, front_mi=1)
add(finish('opslabs_ont', bm, [mat('opslabs_white_plastic'), mat('opslabs_ont_front')]), 40.0, 'PLASTIC')

# ---------------------------------------------------------------------------
# drawables + ytyp
# ---------------------------------------------------------------------------

scene = bpy.context.scene
scene.create_seperate_drawables = True
drawables = []
for obj, lod, colmat in models:
    scene.auto_create_embedded_col = colmat is not None
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.sollumz.converttodrawable()
    d = obj.parent
    drawables.append((d, lod))
    if colmat:
        idx = next((i for i, m in enumerate(sz_col.collisionmats) if m.name == colmat), 0)
        cm = sz_col.create_collision_material_from_index(idx)
        for child in d.children_recursive:
            if child.type == 'MESH' and 'poly_mesh' in child.name:
                child.data.materials.clear()
                child.data.materials.append(cm)
print('DRAWABLES', len(drawables))

bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_telecom_props'
bpy.ops.object.select_all(action='DESELECT')
for d, _ in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0][0]
bpy.ops.sollumz.createarchetypefromselected()
lods = {d.name: lod for d, lod in drawables}
for a in ytyp.archetypes:
    a.lod_dist = lods.get(a.name, 60.0)
print('ARCHETYPES', len(ytyp.archetypes))
res = bpy.ops.sollumz.export_assets(directory=OUT, direct_export=True, use_custom_settings=True,
                                    target_formats={'CWXML'}, target_versions={'GEN8'}, limit_to_selected=False, export_ytyps=True)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_telecom.blend'))
