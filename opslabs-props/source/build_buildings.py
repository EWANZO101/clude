"""Placeable walk-in buildings.
  opslabs_house_customer  11 x 8 m bungalow, gable roof. Living room (front door), kitchen, bedroom; furniture.
                          Outside walls take an anchor / CSP, inside walls the ONT and router. Origin: centre of the floor.
  opslabs_depot           22 x 14 m OPS Openline engineering depot: office + kit room, warehouse with a roller
                          shutter bay, pallet racking full of cable drums, workbench, high-bay lights.
blender -b --python build_buildings.py -- <out_dir>      Fronts face -Y.
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
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], 'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
    'L': ['10000', '10000', '10000', '10000', '10000', '10000', '11111'], 'P': ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], 'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'],
    'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'], 'I': ['11111', '00100', '00100', '00100', '00100', '00100', '11111'],
    'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'], ' ': ['00000'] * 7,
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


import random
rnd = random.Random(5)
# ---- house textures
c = Canvas(128, 128, (226, 214, 190)); c.noise(7); save(c, 'opslabs_hs_render')                       # cream render
c = Canvas(64, 64, (238, 234, 226)); c.noise(2); save(c, 'opslabs_hs_paint')                         # interior paint
c = Canvas(256, 256, (150, 104, 66))                                                                  # oak planks
for row in range(0, 256, 32):
    off = rnd.randint(0, 200)
    sh = rnd.randint(-16, 14)
    c.rect(0, row, 256, row + 31, (150 + sh, 104 + sh, 66 + sh // 2))
    c.rect(0, row + 31, 256, row + 32, (96, 64, 40)); c.rect(off, row, off + 2, row + 32, (96, 64, 40))
c.noise(6); save(c, 'opslabs_hs_floor')
c = Canvas(128, 128, (64, 66, 72))                                                                    # roof tiles
for row in range(0, 128, 16):
    off = 0 if (row // 16) % 2 == 0 else 8
    for x in range(-8 + off, 128, 16):
        sh = rnd.randint(-8, 8)
        c.rect(x + 1, row + 1, x + 15, row + 14, (64 + sh, 66 + sh, 72 + sh))
c.noise(4); save(c, 'opslabs_hs_roof')
c = Canvas(64, 64, (60, 78, 96)); c.rect(30, 0, 34, 64, (240, 240, 240)); c.rect(0, 30, 64, 34, (240, 240, 240)); save(c, 'opslabs_hs_glass')
c = Canvas(32, 32, (255, 246, 222)); save(c, 'opslabs_hs_light')
c = Canvas(64, 64, (84, 96, 120)); c.noise(8); save(c, 'opslabs_hs_fabric')                           # sofa / bed
c = Canvas(64, 64, (246, 246, 244)); c.noise(2); save(c, 'opslabs_hs_white')                          # counter top, bedding
c = Canvas(64, 64, (110, 74, 48)); c.noise(5); save(c, 'opslabs_hs_wood')                             # cupboards, door frame
c = Canvas(64, 64, (128, 128, 124)); c.noise(6); save(c, 'opslabs_hs_concrete')
# ---- depot textures
c = Canvas(128, 128, (70, 92, 120))                                                                   # ribbed cladding
for x in range(0, 128, 16):
    c.rect(x, 0, x + 4, 128, (54, 72, 96))
c.noise(3); save(c, 'opslabs_dp_clad')
c = Canvas(128, 128, (200, 204, 208))
for x in range(0, 128, 16):
    c.rect(x, 0, x + 3, 128, (180, 184, 188))
c.noise(2); save(c, 'opslabs_dp_clad_in')
c = Canvas(128, 128, (150, 150, 146)); c.noise(10); save(c, 'opslabs_dp_floor')                     # power-floated concrete
c = Canvas(64, 64, (70, 74, 84)); c.noise(6); save(c, 'opslabs_dp_carpet')
c = Canvas(64, 64, (232, 232, 228)); c.noise(2); save(c, 'opslabs_dp_paint')
c = Canvas(64, 64, (150, 154, 158)); c.noise(4); save(c, 'opslabs_dp_roof')
c = Canvas(64, 64, (40, 52, 66)); c.rect(30, 0, 34, 64, (90, 92, 96)); save(c, 'opslabs_dp_glass')
c = Canvas(32, 32, (250, 252, 255)); save(c, 'opslabs_dp_light')
c = Canvas(512, 64, (20, 74, 140))
text(c, 'OPS OPENLINE DEPOT', 22, 12, 4, (255, 255, 255)); c.noise(2); save(c, 'opslabs_dp_sign')
c = Canvas(64, 64, (232, 110, 20)); c.noise(4); save(c, 'opslabs_dp_beam')                          # racking beams
c = Canvas(64, 64, (50, 80, 150)); c.noise(4); save(c, 'opslabs_dp_upright')
c = Canvas(64, 64, (170, 128, 80)); c.noise(8); save(c, 'opslabs_dp_drum')                           # wooden drum cheeks
c = Canvas(64, 64, (24, 24, 26)); c.rect(0, 0, 64, 4, (60, 60, 64)); c.noise(3); save(c, 'opslabs_dp_cable')
c = Canvas(64, 64, (240, 200, 20)); save(c, 'opslabs_dp_yellow')
c = Canvas(64, 64, (180, 184, 188)); c.noise(6); save(c, 'opslabs_dp_metal')
c = Canvas(64, 64, (120, 122, 128))
for y in range(0, 64, 8):
    c.rect(0, y, 64, y + 2, (90, 92, 98))
save(c, 'opslabs_dp_shutter')
c = Canvas(64, 64, (24, 26, 30)); c.rect(6, 6, 58, 40, (40, 120, 200)); save(c, 'opslabs_dp_screen')

# ---- doors, gates, fencing textures
c = Canvas(128, 256, (132, 92, 58))                                                                   # interior door: oak with panels
for (x0, y0, x1, y1) in ((16, 20, 112, 110), (16, 140, 112, 236)):
    c.rect(x0, y0, x1, y1, (120, 82, 50)); c.rect(x0 + 4, y0 + 4, x1 - 4, y1 - 4, (138, 96, 60))
c.noise(5); save(c, 'opslabs_dr_oak')
c = Canvas(128, 256, (240, 240, 236))                                                                 # composite front door
c.rect(16, 150, 112, 236, (226, 226, 222)); c.noise(2); save(c, 'opslabs_dr_white')
c = Canvas(64, 128, (120, 126, 132)); c.rect(0, 100, 64, 128, (150, 154, 158)); c.noise(4); save(c, 'opslabs_dr_steel')
c = Canvas(32, 64, (26, 28, 32))                                                                      # keypad
for r in range(4):
    for k in range(3):
        c.rect(5 + k * 8, 20 + r * 10, 11 + k * 8, 27 + r * 10, (200, 200, 205))
c.rect(4, 4, 28, 14, (30, 160, 90)); save(c, 'opslabs_dr_keypad')
c = Canvas(64, 64, (210, 212, 214)); c.brushed(10); save(c, 'opslabs_dr_chrome')
c = Canvas(64, 64, (52, 56, 60)); c.noise(4); save(c, 'opslabs_fn_grey')                            # anthracite RAL 7016
c = Canvas(64, 64, (34, 86, 52)); c.noise(4); save(c, 'opslabs_fn_green')                           # RAL 6005
c = Canvas(64, 64, (176, 182, 186)); c.noise(10); save(c, 'opslabs_fn_galv')                        # galvanised
c = Canvas(64, 64, (236, 196, 20)); c.rect(0, 26, 64, 38, (20, 20, 20)); save(c, 'opslabs_fn_yellow')
c = Canvas(128, 32, (246, 246, 246))                                                                 # barrier arm, red bands
for x in range(0, 128, 32):
    c.rect(x, 0, x + 16, 32, (220, 30, 36))
save(c, 'opslabs_fn_arm')
c = Canvas(64, 64, (60, 64, 68)); c.rect(0, 40, 64, 46, (230, 230, 230)); c.rect(0, 50, 64, 54, (230, 230, 230)); c.noise(3); save(c, 'opslabs_fn_bollard')
c = Canvas(64, 64, (30, 32, 36)); c.noise(3); save(c, 'opslabs_fn_board')
c = Canvas(512, 256, (10, 132, 255)); c.rect(0, 70, 512, 256, (246, 246, 244))                       # sign placeholder (live text replaces it)
save(c, 'opslabs_fn_signdefault')
for n in range(1, 13):
    c = Canvas(64, 32, (246, 246, 244)); c.rect(0, 0, 64, 9, (10, 132, 255)); save(c, 'opslabs_fencesign_%d' % n)
# ---- house extras
c = Canvas(64, 64, (210, 226, 232)); c.noise(3); save(c, 'opslabs_hs_tile')                        # bathroom tiles

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


def face(bm, uv, vs, mi, uvs):
    f = bm.faces.new([bm.verts.new(v) for v in vs])
    f.material_index = mi
    for loop, u in zip(f.loops, uvs):
        loop[uv].uv = u
    return f


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, faces=None, tile=None):
    """faces = {side: material} overrides; tile = metres per texture repeat"""
    F = {
        'front': ([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (x1 - x0, z1 - z0)),
        'back': ([(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], (x1 - x0, z1 - z0)),
        'left': ([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], (y1 - y0, z1 - z0)),
        'right': ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], (y1 - y0, z1 - z0)),
        'top': ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (x1 - x0, y1 - y0)),
        'bottom': ([(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], (x1 - x0, y1 - y0)),
    }
    for k, (vs, (w, h)) in F.items():
        uu, vv = (w / tile, h / tile) if tile else (1, 1)
        face(bm, uv, vs, (faces or {}).get(k, mi), ((0, 0), (uu, 0), (uu, vv), (0, vv)))


def cyl(bm, uv, p0, p1, r, sides=12, mi=0, cap=None):
    import mathutils
    a, b = mathutils.Vector(p0), mathutils.Vector(p1)
    d = (b - a).normalized()
    t = mathutils.Vector((1, 0, 0)) if abs(d.x) < 0.9 else mathutils.Vector((0, 1, 0))
    u = d.cross(t).normalized()
    w = d.cross(u).normalized()
    rings = [[bm.verts.new(c + (u * math.cos(2 * math.pi * i / sides) + w * math.sin(2 * math.pi * i / sides)) * r) for i in range(sides)] for c in (a, b)]
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
        f.material_index = mi
        for loop, uvv in zip(f.loops, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, 1), (i / sides, 1))):
            loop[uv].uv = uvv
    for k, ring in enumerate(rings):
        f = bm.faces.new(ring if k else list(reversed(ring)))
        f.material_index = mi if cap is None else cap
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)


def roof_slope(bm, uv, x0, x1, ya, za, yb, zb, thick, mi_top, mi_under, tile=1.5):
    """a sloped roof plane from eave (ya, za) to ridge (yb, zb) across x0..x1, with thickness"""
    L = math.hypot(yb - ya, zb - za)
    w = x1 - x0
    top = [(x0, ya, za), (x1, ya, za), (x1, yb, zb), (x0, yb, zb)]
    if ya > yb:                                                            # keep the top face pointing up
        top = [(x1, ya, za), (x0, ya, za), (x0, yb, zb), (x1, yb, zb)]
    face(bm, uv, top, mi_top, ((0, 0), (w / tile, 0), (w / tile, L / tile), (0, L / tile)))
    und = [(p[0], p[1], p[2] - thick) for p in reversed(top)]
    face(bm, uv, und, mi_under, ((0, 0), (w / 2, 0), (w / 2, L / 2), (0, L / 2)))
    # eave fascia
    e = [p for p in top if abs(p[1] - ya) < 1e-6]
    e0, e1 = sorted(e, key=lambda p: p[0])
    fv = [e0, (e0[0], e0[1], e0[2] - thick), (e1[0], e1[1], e1[2] - thick), e1]
    if ya < yb:
        fv = list(reversed(fv))
    face(bm, uv, fv, mi_under, ((0, 0), (1, 0), (1, 1), (0, 1)))


def gable(bm, uv, x, xo, y0, y1, z0, zr, mi, tile=2.0):
    """triangular gable wall at x (thickness to x+xo) from eaves z0 (y0..y1) up to the ridge zr at the middle"""
    ym = (y0 + y1) / 2
    w, h = (y1 - y0) / tile, (zr - z0) / tile
    tri_out = [(x, y1, z0), (x, y0, z0), (x, ym, zr)] if xo > 0 else [(x, y0, z0), (x, y1, z0), (x, ym, zr)]
    face(bm, uv, tri_out, mi[0], ((0, 0), (w, 0), (w / 2, h)))
    tri_in = [(p[0] + xo, p[1], p[2]) for p in reversed(tri_out)]
    face(bm, uv, tri_in, mi[1], ((0, 0), (w, 0), (w / 2, h)))


def wall(bm, uv, axis, f0, f1, a0, a1, h, openings, out_mi, in_mi, glass_mi, out_side, z0=0.0, tile=2.0, frame_mi=None):
    """straight wall running along `axis` ('x' or 'y') from a0 to a1, thickness f0..f1 on the other axis.
    openings: [(a, b, zbottom, ztop, 'door'|'window')]. out_side: which box face is the outside."""
    inside = {'front': 'back', 'back': 'front', 'left': 'right', 'right': 'left'}[out_side]
    faces = {out_side: out_mi, inside: in_mi}

    def piece(a, b, za, zb, mi=None, fc=None):
        if b - a < 1e-4 or zb - za < 1e-4:
            return
        if axis == 'x':
            box(bm, uv, a, f0, za, b, f1, zb, mi=in_mi if mi is None else mi, faces=fc if fc is not None else faces, tile=tile)
        else:
            box(bm, uv, f0, a, za, f1, b, zb, mi=in_mi if mi is None else mi, faces=fc if fc is not None else faces, tile=tile)

    cur = a0
    for (a, b, za, zb, kind) in sorted(openings):
        piece(cur, a, z0, h)
        piece(a, b, z0, za)
        piece(a, b, zb, h)
        if kind == 'window':
            m = (f0 + f1) / 2
            if axis == 'x':
                box(bm, uv, a, m - 0.02, za, b, m + 0.02, zb, mi=glass_mi)
            else:
                box(bm, uv, m - 0.02, a, za, m + 0.02, b, zb, mi=glass_mi)
        if frame_mi is not None:                                            # thin frame round the opening
            fr = 0.05
            for (pa, pb, qa, qb) in ((a - fr, a, za, zb), (b, b + fr, za, zb), (a - fr, b + fr, zb, zb + fr)) + (((a - fr, b + fr, za - fr, za),) if kind == 'window' else ()):
                if axis == 'x':
                    box(bm, uv, pa, f0 - 0.02, qa, pb, f1 + 0.02, qb, mi=frame_mi)
                else:
                    box(bm, uv, f0 - 0.02, pa, qa, f1 + 0.02, pb, qb, mi=frame_mi)
        cur = b
    piece(cur, a1, z0, h)


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


YTYP_NAME = 'opslabs_building_props'

# =========================================================================================
# CUSTOMER HOUSE 12 x 9 m — central hall, living room, kitchen, bathroom, two bedrooms
# materials: 0 render, 1 paint, 2 floor, 3 roof, 4 glass, 5 light, 6 fabric, 7 white, 8 wood, 9 concrete, 10 tile
# =========================================================================================
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H, T = 12.0, 9.0, 2.8, 0.25
hx, hy = W / 2, D / 2
FL = 0.12
box(bm, uv, -hx, -hy, -0.4, hx, hy, 0.06, mi=9, tile=2.0)
box(bm, uv, -hx + T, -hy + T, 0.06, hx - T, hy - T, FL, mi=2, tile=2.0)
box(bm, uv, 0.66, 0.06, FL, hx - T, 1.74, FL + 0.005, mi=10, tile=0.6)          # bathroom floor tiles (on top of the oak)
WZ0, WZ1 = 0.95, 2.15
DOOR = 2.15
wall(bm, uv, 'x', -hy, -hy + T, -hx, hx, H, [(-0.95, 0.0, 0.0, DOOR, 'door'), (-4.6, -2.6, WZ0, WZ1, 'window'), (2.0, 4.5, WZ0, WZ1, 'window')], 0, 1, 4, 'front', frame_mi=7)
wall(bm, uv, 'x', hy - T, hy, -hx, hx, H, [(-0.95, 0.0, 0.0, DOOR, 'door'), (2.6, 4.4, WZ0, WZ1, 'window')], 0, 1, 4, 'back', frame_mi=7)
wall(bm, uv, 'y', -hx, -hx + T, -hy + T, hy - T, H, [(-2.6, -1.0, WZ0, WZ1, 'window'), (1.2, 2.8, WZ0, WZ1, 'window')], 0, 1, 4, 'left', frame_mi=7)
wall(bm, uv, 'y', hx - T, hx, -hy + T, hy - T, H, [(-2.6, -1.0, WZ0, WZ1, 'window'), (0.7, 1.4, 1.5, 2.1, 'window'), (2.6, 4.0, WZ0, WZ1, 'window')], 0, 1, 4, 'right', frame_mi=7)
PT = 0.12
ID = 2.1
wall(bm, uv, 'y', -1.6 - PT / 2, -1.6 + PT / 2, -hy + T, hy - T, H, [(-2.6, -1.7, 0.0, ID, 'door'), (1.5, 2.4, 0.0, ID, 'door')], 1, 1, 4, 'left', z0=FL, frame_mi=8)
wall(bm, uv, 'y', 0.6 - PT / 2, 0.6 + PT / 2, -hy + T, hy - T, H, [(-2.6, -1.7, 0.0, ID, 'door'), (0.5, 1.4, 0.0, ID, 'door'), (2.6, 3.5, 0.0, ID, 'door')], 1, 1, 4, 'right', z0=FL, frame_mi=8)
wall(bm, uv, 'x', -PT / 2, PT / 2, -hx + T, -1.6 - PT / 2, H, [], 1, 1, 4, 'front', z0=FL)
wall(bm, uv, 'x', -PT / 2, PT / 2, 0.6 + PT / 2, hx - T, H, [], 1, 1, 4, 'front', z0=FL)
wall(bm, uv, 'x', 1.8 - PT / 2, 1.8 + PT / 2, 0.6 + PT / 2, hx - T, H, [], 10, 1, 4, 'front', z0=FL)
box(bm, uv, -hx + T, -hy + T, H - 0.04, hx - T, hy - T, H, mi=1, tile=2.0)
OV = 0.45
roof_slope(bm, uv, -hx - OV, hx + OV, -hy - OV, H - 0.1, 0.0, 4.7, 0.14, 3, 1)
roof_slope(bm, uv, -hx - OV, hx + OV, hy + OV, H - 0.1, 0.0, 4.7, 0.14, 3, 1)
box(bm, uv, -hx - OV, -0.12, 4.62, hx + OV, 0.12, 4.77, mi=3)
gable(bm, uv, -hx, T, -hy, hy, H, 4.6, (0, 1))
gable(bm, uv, hx, -T, -hy, hy, H, 4.6, (0, 1))
box(bm, uv, -4.4, 1.8, 3.5, -3.6, 2.5, 5.4, mi=0, tile=1.0)                   # chimney
box(bm, uv, -1.25, -hy - 0.8, -0.1, 0.3, -hy, 0.06, mi=9)                    # front step
box(bm, uv, -1.5, -hy - 1.0, 2.45, 0.55, -hy, 2.55, mi=8)                    # canopy
for (x, y) in ((-3.8, -2.2), (3.3, -2.2), (-3.8, 2.2), (3.3, 0.9), (3.3, 3.2), (-0.5, -2.0), (-0.5, 2.0)):
    box(bm, uv, x - 0.22, y - 0.22, H - 0.07, x + 0.22, y + 0.22, H - 0.04, mi=5)
# living room
box(bm, uv, -5.5, -3.4, FL, -4.6, -1.4, FL + 0.45, mi=6)
box(bm, uv, -5.75, -3.4, FL, -5.5, -1.4, FL + 0.85, mi=6)
box(bm, uv, -4.2, -3.0, FL, -3.4, -1.8, FL + 0.4, mi=8)
box(bm, uv, -4.6, -0.55, FL, -2.8, -0.06, FL + 0.5, mi=8)
box(bm, uv, -4.2, -0.32, FL + 0.5, -3.2, -0.26, FL + 1.1, mi=6)
# kitchen: worktops along the right and front walls, table
box(bm, uv, hx - T - 0.6, -hy + T, FL, hx - T, -0.6, FL + 0.86, mi=8)
box(bm, uv, hx - T - 0.62, -hy + T, FL + 0.86, hx - T, -0.6, FL + 0.9, mi=7)
box(bm, uv, 2.0, -hy + T, FL, hx - T - 0.6, -hy + T + 0.6, FL + 0.86, mi=8)
box(bm, uv, 2.0, -hy + T, FL + 0.86, hx - T - 0.6, -hy + T + 0.62, FL + 0.9, mi=7)
box(bm, uv, 2.4, -2.4, FL, 3.6, -1.4, FL + 0.74, mi=8)
# bathroom: bath, toilet, basin
box(bm, uv, 4.1, 0.06, FL, hx - T, 0.8, FL + 0.55, mi=7)
box(bm, uv, 3.0, 1.2, FL, 3.45, 1.74, FL + 0.42, mi=7)
box(bm, uv, 3.05, 1.6, FL + 0.42, 3.4, 1.74, FL + 0.8, mi=7)
box(bm, uv, 2.0, 1.35, FL + 0.7, 2.5, 1.74, FL + 0.85, mi=7)
box(bm, uv, 2.15, 1.5, FL, 2.35, 1.74, FL + 0.7, mi=7)
# bedroom 1 (back left)
box(bm, uv, -5.0, 2.4, FL, -3.2, hy - T, FL + 0.5, mi=7)
box(bm, uv, -5.0, hy - T - 0.08, FL, -3.2, hy - T, FL + 1.05, mi=8)
box(bm, uv, -2.3, 3.0, FL, -1.72, 4.2, FL + 2.0, mi=8)
# bedroom 2 (back right)
box(bm, uv, 3.4, 2.6, FL, 5.2, hy - T, FL + 0.5, mi=6)
box(bm, uv, 3.4, hy - T - 0.08, FL, 5.2, hy - T, FL + 1.05, mi=8)
box(bm, uv, 0.9, 3.7, FL, 2.0, hy - T, FL + 0.74, mi=8)
add(finish('opslabs_house_customer', bm, [mat('opslabs_hs_render'), mat('opslabs_hs_paint'), mat('opslabs_hs_floor'), mat('opslabs_hs_roof'),
                                          mat('opslabs_hs_glass'), mat('opslabs_hs_light', 'emissive.sps'), mat('opslabs_hs_fabric'),
                                          mat('opslabs_hs_white'), mat('opslabs_hs_wood'), mat('opslabs_hs_concrete'), mat('opslabs_hs_tile')]), 400.0, 'CONCRETE')

# =========================================================================================
# DEPOT 22 x 14 m — office, corridor, meeting room, kit room, lockers & WC, warehouse
# 0 cladding, 1 cladding inside, 2 concrete floor, 3 carpet, 4 office paint, 5 roof, 6 glass, 7 light, 8 sign,
# 9 beam, 10 upright, 11 drum, 12 cable, 13 yellow, 14 metal, 15 shutter, 16 screen
# =========================================================================================
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H, T = 22.0, 14.0, 6.0, 0.25
hx, hy = W / 2, D / 2
box(bm, uv, -hx, -hy, -0.4, hx, hy, 0.08, mi=2, tile=3.0)
OX = -3.0
box(bm, uv, -hx + T, -hy + T, 0.08, OX - 0.1, hy - T, 0.1, mi=3, tile=2.0)
wall(bm, uv, 'x', -hy, -hy + T, -hx, hx, H, [(-10.2, -8.4, 1.0, 2.3, 'window'), (-7.6, -6.6, 0.0, 2.2, 'door'), (-5.8, -3.6, 1.0, 2.3, 'window'),
                                             (1.0, 6.5, 0.0, 4.6, 'door')], 0, 1, 6, 'front', frame_mi=14)
wall(bm, uv, 'x', hy - T, hy, -hx, hx, H, [(-10.2, -8.8, 1.2, 2.3, 'window'), (-7.4, -6.0, 1.2, 2.3, 'window')], 0, 1, 6, 'back', frame_mi=14)
wall(bm, uv, 'y', -hx, -hx + T, -hy + T, hy - T, H, [(-5.0, -3.0, 1.0, 2.3, 'window'), (2.5, 4.5, 1.0, 2.3, 'window')], 0, 1, 6, 'left', frame_mi=14)
wall(bm, uv, 'y', hx - T, hx, -hy + T, hy - T, H, [(-1.0, 0.0, 0.0, 2.2, 'door')], 0, 1, 6, 'right', frame_mi=14)
OH = 3.2
wall(bm, uv, 'y', OX - 0.1, OX + 0.1, -hy + T, hy - T, OH, [(-5.0, -2.5, 1.0, 2.1, 'window'), (-0.7, 0.3, 0.0, 2.1, 'door')], 4, 4, 6, 'left', frame_mi=14)
wall(bm, uv, 'x', -1.06, -0.94, -hx + T, OX - 0.1, OH, [(-6.0, -5.1, 0.0, 2.1, 'door')], 4, 4, 6, 'front', z0=0.1, frame_mi=14)
wall(bm, uv, 'x', 0.44, 0.56, -hx + T, OX - 0.1, OH, [(-9.8, -8.9, 0.0, 2.1, 'door'), (-7.2, -6.3, 0.0, 2.1, 'door'), (-4.7, -3.8, 0.0, 2.1, 'door')], 4, 4, 6, 'front', z0=0.1, frame_mi=14)
wall(bm, uv, 'y', -8.06, -7.94, 0.56, hy - T, OH, [], 4, 4, 6, 'left', z0=0.1)
wall(bm, uv, 'y', -5.56, -5.44, 0.56, hy - T, OH, [], 4, 4, 6, 'left', z0=0.1)
box(bm, uv, -hx + T, -hy + T, OH, OX + 0.1, hy - T, OH + 0.12, mi=4, tile=2.0)
for (x, y) in ((-8.0, -4.0), (-5.0, -4.0), (-7.0, -0.25), (-9.4, 3.6), (-6.75, 3.6), (-4.3, 3.6)):
    box(bm, uv, x - 0.5, y - 0.25, OH - 0.04, x + 0.5, y + 0.25, OH - 0.01, mi=7)
roof_slope(bm, uv, -hx - 0.3, hx + 0.3, -hy - 0.3, H - 0.05, 0.0, 7.0, 0.15, 5, 1)
roof_slope(bm, uv, -hx - 0.3, hx + 0.3, hy + 0.3, H - 0.05, 0.0, 7.0, 0.15, 5, 1)
gable(bm, uv, -hx, T, -hy, hy, H, 6.95, (0, 1))
gable(bm, uv, hx, -T, -hy, hy, H, 6.95, (0, 1))
box(bm, uv, -9.6, -hy - 0.06, 3.0, -4.2, -hy, 3.8, mi=8, faces={'front': 8})
box(bm, uv, -8.1, -hy - 1.0, 2.55, -6.1, -hy, 2.65, mi=14)
cyl(bm, uv, (1.0, -hy + 0.55, 4.95), (6.5, -hy + 0.55, 4.95), 0.32, sides=14, mi=15)          # shutter drum
for x in (0.85, 6.5):
    box(bm, uv, x, -hy + T, 0.08, x + 0.15, -hy + T + 0.15, 4.6, mi=14)
for (x0, y0, x1, y1) in ((-2.6, -6.6, -2.5, 6.6), (0.6, -6.6, 0.7, 6.6), (0.7, -0.4, 10.6, -0.3), (1.0, -6.6, 1.1, -1.0), (6.4, -6.6, 6.5, -1.0)):
    box(bm, uv, x0, y0, 0.08, x1, y1, 0.09, mi=13)
for x in (2.0, 6.5, 9.0):
    for y in (-3.5, 3.0):
        box(bm, uv, x - 0.5, y - 0.5, 5.7, x + 0.5, y + 0.5, 5.75, mi=7)
        cyl(bm, uv, (x, y, 5.75), (x, y, 6.2), 0.03, sides=6, mi=14)
RX0, RX1, RY0, RY1 = 0.0, 10.5, 4.6, 6.3
bays = [RX0 + k * (RX1 - RX0) / 3 for k in range(4)]
for x in bays:
    for y in (RY0, RY1 - 0.08):
        box(bm, uv, x, y, 0.08, x + 0.08, y + 0.08, 4.6, mi=10)
for z in (0.25, 1.8, 3.35):
    for y in (RY0, RY1 - 0.1):
        box(bm, uv, RX0, y, z, RX1 + 0.08, y + 0.1, z + 0.12, mi=9)
    box(bm, uv, RX0, RY0, z + 0.12, RX1 + 0.08, RY1, z + 0.14, mi=14)
    for k in range(3):
        cx = (bays[k] + bays[k + 1]) / 2
        for j, dx in enumerate((-0.85, 0.0, 0.85)):
            rr = 0.55 if j != 1 else 0.6
            x = cx + dx
            zc = z + 0.14 + rr
            yc = (RY0 + RY1) / 2
            cyl(bm, uv, (x - 0.32, yc, zc), (x - 0.27, yc, zc), rr, sides=14, mi=11)
            cyl(bm, uv, (x + 0.27, yc, zc), (x + 0.32, yc, zc), rr, sides=14, mi=11)
            cyl(bm, uv, (x - 0.27, yc, zc), (x + 0.27, yc, zc), rr * 0.8, sides=14, mi=12, cap=11)
box(bm, uv, hx - T - 0.8, 1.0, 0.08, hx - T, 4.0, 0.95, mi=14)
box(bm, uv, hx - T - 0.82, 1.0, 0.95, hx - T, 4.0, 1.0, mi=11)
box(bm, uv, hx - T - 0.05, 1.0, 1.3, hx - T, 4.0, 2.4, mi=10)
for z in (1.0, 2.2):
    box(bm, uv, 7.0, -hy + T, z, 10.4, -hy + T + 0.3, z + 0.06, mi=14)
# office desks + screens
for (x, y) in ((-9.5, -4.2), (-5.4, -4.2)):
    box(bm, uv, x - 0.8, y - 0.4, 0.1, x + 0.8, y + 0.4, 0.84, mi=14)
    box(bm, uv, x - 0.3, y + 0.15, 0.84, x + 0.3, y + 0.2, 1.2, mi=16, faces={'front': 16})
# meeting room table, kit room shelving, lockers
box(bm, uv, -10.2, 3.0, 0.1, -8.6, 5.2, 0.84, mi=14)
for y in (1.6, 3.4, 5.2):
    box(bm, uv, -7.9, y, 0.1, -7.4, y + 1.2, 2.2, mi=10)
for k in range(5):
    x = -5.3 + k * 0.42
    box(bm, uv, x, hy - T - 0.5, 0.1, x + 0.4, hy - T, 1.9, mi=14)
add(finish('opslabs_depot', bm, [mat('opslabs_dp_clad'), mat('opslabs_dp_clad_in'), mat('opslabs_dp_floor'), mat('opslabs_dp_carpet'),
                                 mat('opslabs_dp_paint'), mat('opslabs_dp_roof'), mat('opslabs_dp_glass'), mat('opslabs_dp_light', 'emissive.sps'),
                                 mat('opslabs_dp_sign'), mat('opslabs_dp_beam'), mat('opslabs_dp_upright'), mat('opslabs_dp_drum'),
                                 mat('opslabs_dp_cable'), mat('opslabs_dp_yellow'), mat('opslabs_dp_metal'), mat('opslabs_dp_shutter'),
                                 mat('opslabs_dp_screen')]), 500.0, 'CONCRETE')

# =========================================================================================
# DOOR LEAVES (origin = bottom of the hinge edge, leaf runs +X, faces ±Y)
# =========================================================================================
def leaf(name, w, hgt, body, extras):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, 0.01, -0.022, 0.0, w - 0.01, 0.022, hgt, mi=0)
    for side in (-1, 1):
        y = side * 0.022
        cyl(bm, uv, (w - 0.09, y, 1.0), (w - 0.09, y + side * 0.06, 1.0), 0.012, sides=8, mi=1)
        cyl(bm, uv, (w - 0.09, y + side * 0.06, 1.0), (w - 0.21, y + side * 0.06, 1.0), 0.011, sides=8, mi=1)
    extras(bm, uv)
    add(finish(name, bm, body), 80.0, 'WOOD_SOLID_MEDIUM')


def keypads(bm, uv, w, mi):
    for side in (-1, 1):
        y0, y1 = (-0.022 - 0.025, -0.022) if side < 0 else (0.022, 0.022 + 0.025)
        box(bm, uv, w - 0.16, y0, 1.18, w - 0.06, y1, 1.34, mi=mi, faces={'front' if side < 0 else 'back': mi})


leaf('opslabs_door_int', 0.9, 2.0, [mat('opslabs_dr_oak'), mat('opslabs_dr_chrome'), mat('opslabs_dr_keypad')],
     lambda bm, uv: keypads(bm, uv, 0.9, 2))
leaf('opslabs_door_ext', 0.95, 2.0, [mat('opslabs_dr_white'), mat('opslabs_dr_chrome'), mat('opslabs_dr_keypad'), mat('opslabs_hs_glass')],
     lambda bm, uv: (keypads(bm, uv, 0.95, 2), box(bm, uv, 0.3, -0.026, 1.25, 0.62, 0.026, 1.85, mi=3)))
leaf('opslabs_door_steel', 1.0, 2.0, [mat('opslabs_dr_steel'), mat('opslabs_dr_chrome'), mat('opslabs_dr_keypad'), mat('opslabs_dp_glass')],
     lambda bm, uv: (keypads(bm, uv, 1.0, 2), box(bm, uv, 0.35, -0.026, 1.3, 0.65, 0.026, 1.8, mi=3),
                     box(bm, uv, 0.1, 0.022, 0.95, 0.85, 0.07, 1.02, mi=1)))
# roller shutter: origin top-left, hangs down 4.6 m, 5.5 m wide (opens by swinging up under the roof)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, 0.0, -0.04, -4.6, 5.5, 0.04, 0.0, mi=0, tile=1.0)
box(bm, uv, 0.0, -0.06, -4.6, 5.5, 0.06, -4.5, mi=1)
add(finish('opslabs_door_shutter', bm, [mat('opslabs_dp_shutter'), mat('opslabs_dp_metal')]), 150.0, 'METAL_SOLID_MEDIUM')

# =========================================================================================
# FENCING, GATES, BOLLARDS   (fence panels: 2.5 m along X, centred; posts at -X end)
# =========================================================================================
def palisade(bm, uv, x0, x1, z0, z1, mi, pitch=0.15):
    box(bm, uv, x0, -0.06, z0 + 0.25, x1, -0.02, z0 + 0.32, mi=mi)                   # rails
    box(bm, uv, x0, -0.06, z1 - 0.45, x1, -0.02, z1 - 0.38, mi=mi)
    x = x0 + 0.04
    while x + 0.07 <= x1 - 0.02:
        box(bm, uv, x, -0.02, z0 + 0.08, x + 0.07, 0.0, z1 - 0.06, mi=mi)            # pale
        box(bm, uv, x + 0.02, -0.02, z1 - 0.06, x + 0.05, 0.0, z1, mi=mi)            # point
        x += pitch


def mesh_panel(bm, uv, x0, x1, z0, z1, mi):
    for k in range(int((x1 - x0) / 0.15) + 1):
        x = x0 + k * 0.15
        box(bm, uv, x, -0.004, z0, x + 0.008, 0.004, z1, mi=mi)
    for k in range(int((z1 - z0) / 0.2) + 1):
        z = z0 + k * 0.2
        box(bm, uv, x0, -0.006, z, x1, 0.006, z + 0.008, mi=mi)


FINISH = (('grey', 'opslabs_fn_grey'), ('green', 'opslabs_fn_green'), ('galv', 'opslabs_fn_galv'))
for key, tex in FINISH:
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -1.3, -0.05, -0.5, -1.2, 0.05, 2.5, mi=0)
    palisade(bm, uv, -1.2, 1.25, 0.0, 2.4, 0)
    add(finish('opslabs_fence_pal_' + key, bm, [mat(tex)]), 150.0, 'METAL_SOLID_MEDIUM')
for key, tex in FINISH[:2]:
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -1.3, -0.04, -0.5, -1.22, 0.04, 2.5, mi=0)
    mesh_panel(bm, uv, -1.22, 1.25, 0.05, 2.4, 0)
    add(finish('opslabs_fence_mesh_' + key, bm, [mat(tex)]), 120.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')                              # branded panel: palisade + sign board
box(bm, uv, -1.3, -0.05, -0.5, -1.2, 0.05, 2.5, mi=0)
palisade(bm, uv, -1.2, 1.25, 0.0, 2.4, 0)
box(bm, uv, -0.65, -0.1, 1.02, 0.65, -0.06, 1.68, mi=1)
add(finish('opslabs_fence_brand', bm, [mat('opslabs_fn_grey'), mat('opslabs_fn_board')]), 150.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.06, -0.06, -0.5, 0.06, 0.06, 2.55, mi=0)
add(finish('opslabs_fence_post', bm, [mat('opslabs_fn_grey')]), 120.0, 'METAL_SOLID_MEDIUM')
# sign boards: 1.2 x 0.6, centred, face -Y. 'opslabs_fence_sign' is the placeable one; 1..12 are the live-text slots
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.6, -0.012, -0.3, 0.6, 0.012, 0.3, mi=1, faces={'front': 0})
add(finish('opslabs_fence_sign', bm, [mat('opslabs_fn_signdefault'), mat('opslabs_fn_board')]), 80.0, None)
for n in range(1, 13):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -0.6, -0.012, -0.3, 0.6, 0.012, 0.3, mi=1, faces={'front': 0})
    add(finish('opslabs_fencesign_%d' % n, bm, [mat('opslabs_fencesign_%d' % n), mat('opslabs_fn_board')]), 80.0, None)


def gate_leaf(name, w, hgt, mi_tex, board=False):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, 0.0, -0.05, 0.08, w, 0.0, 0.2, mi=0)                                      # bottom frame
    box(bm, uv, 0.0, -0.05, hgt - 0.12, w, 0.0, hgt, mi=0)                                # top frame
    box(bm, uv, 0.0, -0.05, 0.08, 0.06, 0.0, hgt, mi=0)
    box(bm, uv, w - 0.06, -0.05, 0.08, w, 0.0, hgt, mi=0)
    x = 0.12
    while x + 0.05 <= w - 0.08:
        box(bm, uv, x, -0.035, 0.2, x + 0.05, -0.015, hgt - 0.12, mi=0)
        x += 0.13
    mats = [mat(mi_tex)]
    if board:
        box(bm, uv, w / 2 - 0.65, -0.075, hgt / 2 - 0.36, w / 2 + 0.65, -0.05, hgt / 2 + 0.36, mi=1)
        mats.append(mat('opslabs_fn_board'))
    return bm, uv, mats


bm, uv, mats = gate_leaf('opslabs_gate_slide', 5.2, 2.0, 'opslabs_fn_grey', board=True)
for x in (0.5, 4.7):
    cyl(bm, uv, (x, -0.06, 0.06), (x, 0.01, 0.06), 0.06, sides=10, mi=0)                 # wheels
add(finish('opslabs_gate_slide', bm, mats), 150.0, 'METAL_SOLID_MEDIUM')
bm, uv, mats = gate_leaf('opslabs_gate_leaf', 2.0, 1.9, 'opslabs_fn_grey', board=True)
add(finish('opslabs_gate_leaf', bm, mats), 150.0, 'METAL_SOLID_MEDIUM')
bm, uv, mats = gate_leaf('opslabs_gate_ped', 1.1, 1.9, 'opslabs_fn_grey')
add(finish('opslabs_gate_ped', bm, mats), 100.0, 'METAL_SOLID_MEDIUM')


def keypad_pillar(bm, uv, x, y, mi_body, mi_pad):
    box(bm, uv, x - 0.08, y - 0.08, 0.0, x + 0.08, y + 0.08, 1.2, mi=mi_body)
    box(bm, uv, x - 0.07, y - 0.1, 1.0, x + 0.07, y - 0.08, 1.18, mi=mi_pad, faces={'front': mi_pad})


# sliding gate frame: opening x -2.6..2.6, leaf slides to -7.9..-2.7; keypad on the approach side (-Y)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -8.0, -0.12, -0.05, 2.6, 0.06, 0.02, mi=0)                                    # track
box(bm, uv, -2.85, 0.02, -0.4, -2.65, 0.22, 2.2, mi=0)                                    # guide post (behind the leaf)
box(bm, uv, 2.6, -0.15, -0.4, 2.8, 0.1, 2.2, mi=0)                                        # catch post
box(bm, uv, -8.1, 0.02, -0.4, -7.9, 0.22, 2.2, mi=0)                                      # end stop
keypad_pillar(bm, uv, 3.5, -1.0, 0, 1)
add(finish('opslabs_gate_slide_frame', bm, [mat('opslabs_fn_grey'), mat('opslabs_dr_keypad')]), 150.0, 'METAL_SOLID_MEDIUM')
# double swing gate frame: posts at ±2.15, leaves hinge at ±2.05
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
for x in (-2.15, 2.15):
    box(bm, uv, x - 0.08, -0.08, -0.4, x + 0.08, 0.08, 2.2, mi=0)
    box(bm, uv, x - 0.1, -0.1, 2.2, x + 0.1, 0.1, 2.26, mi=0)
keypad_pillar(bm, uv, 3.0, -1.0, 0, 1)
add(finish('opslabs_gate_swing_frame', bm, [mat('opslabs_fn_grey'), mat('opslabs_dr_keypad')]), 150.0, 'METAL_SOLID_MEDIUM')
# pedestrian gate frame: posts at ±0.62, leaf hinge at -0.55
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
for x in (-0.62, 0.62):
    box(bm, uv, x - 0.05, -0.05, -0.4, x + 0.05, 0.05, 2.1, mi=0)
box(bm, uv, 0.59, -0.08, 1.0, 0.67, -0.05, 1.16, mi=1, faces={'front': 1})
add(finish('opslabs_gate_ped_frame', bm, [mat('opslabs_fn_grey'), mat('opslabs_dr_keypad')]), 120.0, 'METAL_SOLID_MEDIUM')
# car park barrier: housing at the -X side, arm pivots at (-2.1, 0, 0.95), rest post at +2.4
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -2.45, -0.2, 0.0, -2.1, 0.2, 1.05, mi=0)
box(bm, uv, 2.35, -0.05, 0.0, 2.45, 0.05, 0.85, mi=0)
box(bm, uv, 2.3, -0.08, 0.85, 2.5, 0.08, 0.9, mi=0)
keypad_pillar(bm, uv, -3.2, -1.0, 0, 1)
add(finish('opslabs_barrier_housing', bm, [mat('opslabs_fn_yellow'), mat('opslabs_dr_keypad')]), 150.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, 0.0, -0.05, -0.06, 4.4, 0.05, 0.06, mi=0, tile=0.5)
add(finish('opslabs_barrier_arm', bm, [mat('opslabs_fn_arm')]), 150.0, 'PLASTIC')
# bollards
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, -0.3), (0, 0, 1.0), 0.1, sides=14, mi=0)
add(finish('opslabs_bollard_fixed', bm, [mat('opslabs_fn_yellow')]), 120.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, -0.3), (0, 0, 1.0), 0.1, sides=14, mi=0)
add(finish('opslabs_bollard_steel', bm, [mat('opslabs_dr_chrome')]), 120.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')                                # rising bollard: flush sleeve
cyl(bm, uv, (0, 0, -0.05), (0, 0, 0.015), 0.17, sides=16, mi=0)
add(finish('opslabs_bollard_rising', bm, [mat('opslabs_dp_metal')]), 100.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')                                # the moving post (lowers 0.92 m)
cyl(bm, uv, (0, 0, -0.95), (0, 0, 0.9), 0.11, sides=16, mi=0)
add(finish('opslabs_bollard_post', bm, [mat('opslabs_fn_bollard')]), 100.0, 'METAL_SOLID_MEDIUM')

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
bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = YTYP_NAME
bpy.ops.object.select_all(action='DESELECT')
for d, _ in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0][0]
bpy.ops.sollumz.createarchetypefromselected()
lods = {d.name: lod for d, lod in drawables}
for a in ytyp.archetypes:
    a.lod_dist = lods.get(a.name, 100.0)
print('ARCHETYPES', len(ytyp.archetypes))
res = bpy.ops.sollumz.export_assets(directory=OUT, direct_export=True, use_custom_settings=True,
                                    target_formats={'CWXML'}, target_versions={'GEN8'}, limit_to_selected=False, export_ytyps=True)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_buildings.blend'))
