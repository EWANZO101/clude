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


YTYP_NAME = 'opslabs_van_props'
FONT.update({
    'W': ['10001', '10001', '10001', '10101', '10101', '10101', '01010'], 'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    'K': ['10001', '10010', '10100', '11000', '10100', '10010', '10001'], 'F': ['11111', '10000', '10000', '11110', '10000', '10000', '10000'],
    'B': ['11110', '10001', '10001', '11110', '10001', '10001', '11110'], 'M': ['10001', '11011', '10101', '10101', '10001', '10001', '10001'],
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'], 'C': ['01110', '10001', '10000', '10000', '10000', '10001', '01110'],
    'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01111'], 'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
    'U': ['10001', '10001', '10001', '10001', '10001', '10001', '01110'], 'Y': ['10001', '10001', '01010', '00100', '00100', '00100', '00100'],
    '0': ['01110', '10001', '10011', '10101', '11001', '10001', '01110'], '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
    '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'], '-': ['00000', '00000', '00000', '11111', '00000', '00000', '00000'],
    '.': ['00000', '00000', '00000', '00000', '00000', '00000', '00100'], '/': ['00001', '00010', '00010', '00100', '01000', '01000', '10000'],
})
# side livery: white with a blue band, big OPS NETWORK, strapline and phone, chevron tail
c = Canvas(1024, 256, (246, 247, 249))
c.rect(0, 150, 1024, 196, (10, 90, 200)); c.rect(0, 196, 1024, 206, (255, 190, 0))
text(c, 'OPS NETWORK', 40, 30, 14, (10, 60, 150))
text(c, 'FIBRE - POWER - MOBILE', 46, 160, 5, (255, 255, 255))
text(c, 'CALL 555-0100', 600, 215, 5, (10, 60, 150))
c.noise(1); save(c, 'opslabs_van_livery')
# rear: red / yellow chevrons (high visibility) with a white OPS NETWORK strip
c = Canvas(512, 384, (255, 200, 0))
for k in range(-12, 24):
    x = k * 48
    for y in range(0, 384):
        xs = x + (y if k % 2 == 0 else y) // 1
    c.rect(0, 0, 0, 0, (0, 0, 0))
import math as _m
for y in range(384):
    for x in range(512):
        if ((x + abs(y - 192)) // 40) % 2 == 0:
            c._put(x, y, (220, 30, 36))
c.rect(0, 300, 512, 384, (246, 247, 249)); text(c, 'OPS NETWORK', 60, 316, 7, (10, 60, 150))
save(c, 'opslabs_van_chevron')
c = Canvas(32, 32, (40, 30, 10)); save(c, 'opslabs_van_lens_off')
c = Canvas(32, 32, (255, 170, 20)); save(c, 'opslabs_van_lens_on')
c = Canvas(64, 64, (24, 24, 26)); c.noise(3); save(c, 'opslabs_van_black')
c = Canvas(64, 64, (170, 174, 178)); c.noise(6); save(c, 'opslabs_van_alu')

# side panel 2.6 x 0.65 (face -Y), rear panel 1.3 x 1.0
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -1.3, -0.004, -0.325, 1.3, 0.0, 0.325, mi=0, faces={'front': 0})
add(finish('opslabs_van_side', bm, [mat('opslabs_van_livery')]), 120.0, None)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.65, -0.004, -0.5, 0.65, 0.0, 0.5, mi=0, faces={'front': 0})
add(finish('opslabs_van_rear', bm, [mat('opslabs_van_chevron')]), 120.0, None)
# roof light bar 1.3 m: body + 4 lens blocks; *_on_l / *_on_r = lit lenses (left pair / right pair)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.65, -0.14, 0.0, 0.65, 0.14, 0.05, mi=0)
for x in (-0.58, -0.28, 0.02, 0.32):
    box(bm, uv, x, -0.12, 0.05, x + 0.26, 0.12, 0.13, mi=1)
for x in (-0.55, 0.55):
    box(bm, uv, x - 0.03, -0.03, -0.06, x + 0.03, 0.03, 0.0, mi=0)
add(finish('opslabs_van_lightbar', bm, [mat('opslabs_van_black'), mat('opslabs_van_lens_off')]), 120.0, None)
for side, xs in (('l', (-0.58, -0.28)), ('r', (0.02, 0.32))):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    for x in xs:
        box(bm, uv, x - 0.003, -0.123, 0.047, x + 0.263, 0.123, 0.133, mi=0)
    add(finish('opslabs_van_lightbar_on_' + side, bm, [mat('opslabs_van_lens_on', 'emissive.sps')]), 120.0, None)
# rear beacon pods
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.06, -0.06, 0.0, 0.06, 0.06, 0.02, mi=0)
cyl(bm, uv, (0, 0, 0.02), (0, 0, 0.11), 0.05, sides=12, mi=1)
add(finish('opslabs_van_beacon', bm, [mat('opslabs_van_black'), mat('opslabs_van_lens_off')]), 100.0, None)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, 0.019), (0, 0, 0.113), 0.053, sides=12, mi=0)
add(finish('opslabs_van_beacon_on', bm, [mat('opslabs_van_lens_on', 'emissive.sps')]), 100.0, None)
# roof rack 2.4 x 1.4
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
for x in (-0.7, 0.66):
    box(bm, uv, x, -1.2, 0.0, x + 0.04, 1.2, 0.05, mi=0)
for y in (-1.15, -0.4, 0.4, 1.11):
    box(bm, uv, -0.7, y, 0.05, 0.7, y + 0.04, 0.09, mi=0)
for (x, y) in ((-0.7, -1.2), (0.66, -1.2), (-0.7, 1.16), (0.66, 1.16)):
    box(bm, uv, x, y, -0.06, x + 0.04, y + 0.04, 0.0, mi=0)
add(finish('opslabs_van_rack', bm, [mat('opslabs_van_alu')]), 120.0, None)

# MEWP (cherry picker): tracked base, 1 m telescopic mast segments (stacked to height), basket with railings + control box
c = Canvas(64, 64, (240, 180, 0)); c.noise(4); save(c, 'opslabs_mewp_yellow')
c = Canvas(64, 64, (60, 62, 66)); c.noise(5); save(c, 'opslabs_mewp_track')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.6, -1.0, 0.0, -0.3, 1.0, 0.35, mi=1)
box(bm, uv, 0.3, -1.0, 0.0, 0.6, 1.0, 0.35, mi=1)
box(bm, uv, -0.55, -0.8, 0.35, 0.55, 0.8, 0.85, mi=0)
cyl(bm, uv, (0, 0, 0.85), (0, 0, 1.05), 0.25, sides=16, mi=0)
box(bm, uv, 0.3, -0.95, 0.85, 0.5, -0.75, 1.25, mi=1)                                   # ground control box
add(finish('opslabs_mewp_base', bm, [mat('opslabs_mewp_yellow'), mat('opslabs_mewp_track')]), 150.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.11, -0.11, 0.0, 0.11, 0.11, 1.0, mi=0)
box(bm, uv, -0.12, -0.12, 0.96, 0.12, 0.12, 1.0, mi=1)
add(finish('opslabs_mewp_mast', bm, [mat('opslabs_mewp_yellow'), mat('opslabs_mewp_track')]), 150.0, None)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.6, -0.45, 0.0, 0.6, 0.45, 0.06, mi=1)                                     # floor
for (x0, y0, x1, y1) in ((-0.6, -0.45, 0.6, -0.42), (-0.6, 0.42, 0.6, 0.45), (-0.6, -0.45, -0.57, 0.45), (0.57, -0.45, 0.6, 0.45)):
    box(bm, uv, x0, y0, 1.05, x1, y1, 1.1, mi=0)                                            # top rail
    box(bm, uv, x0, y0, 0.5, x1, y1, 0.54, mi=0)                                            # mid rail
for (x, y) in ((-0.6, -0.45), (0.57, -0.45), (-0.6, 0.42), (0.57, 0.42)):
    box(bm, uv, x, y, 0.06, x + 0.03, y + 0.03, 1.1, mi=0)
box(bm, uv, 0.2, 0.3, 0.9, 0.5, 0.42, 1.12, mi=1)                                          # basket controls
add(finish('opslabs_mewp_basket', bm, [mat('opslabs_mewp_yellow'), mat('opslabs_mewp_track')]), 150.0, 'METAL_SOLID_MEDIUM')

# ---------------------------------------------------------------------------------------------
# uniform branding (polished): printed decals with real-font artwork, smooth hard hat with a sticker
# ---------------------------------------------------------------------------------------------
LOGOS = os.path.join(HERE, 'logos')

def png_canvas(name):
    img = bpy.data.images.load(os.path.join(LOGOS, name + '.png'))
    w, h = img.size
    px = list(img.pixels)
    c = Canvas(w, h, (0, 0, 0))
    for y in range(h):
        row = h - 1 - y
        for x in range(w):
            i = (row * w + x) * 4
            r, g, b, a = px[i:i + 4]
            # straight alpha; push the edge colour to the solid colour so mips don't go dark
            c.px[y * w + x] = [int(r * 255 / a) if a > 0 else 255, int(g * 255 / a) if a > 0 else 255, int(b * 255 / a) if a > 0 else 255, int(a * 255)]
    for p in c.px:
        for k in range(3): p[k] = max(0, min(255, p[k]))
    return c

for n in ('uni_back', 'uni_chest', 'uni_hat'):
    save(png_canvas(n), 'opslabs_' + n)
c = Canvas(64, 64, (244, 245, 246)); c.noise(1); save(c, 'opslabs_uni_shell')
c = Canvas(64, 64, (30, 32, 36)); c.noise(2); save(c, 'opslabs_uni_harness')


def curved_patch(bm, uv, w, h, R, mi):
    """a thin curved print, centred on the origin, bulging toward -Y (so it wraps a back or chest)"""
    seg = 16
    half = w / 2 / R
    rows = []
    for k in range(seg + 1):
        a = -half + 2 * half * k / seg
        x, y = R * math.sin(a), R * (1 - math.cos(a))
        rows.append((x, y, k / seg))
    for k in range(seg):
        (x0, y0, u0), (x1, y1, u1) = rows[k], rows[k + 1]
        face(bm, uv, [(x0, y0, -h / 2), (x1, y1, -h / 2), (x1, y1, h / 2), (x0, y0, h / 2)], mi, ((u0, 0), (u1, 0), (u1, 1), (u0, 1)))


bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
curved_patch(bm, uv, 0.34, 0.17, 0.55, 0)
add(finish('opslabs_uniform_back', bm, [mat('opslabs_uni_back', 'decal.sps')]), 60.0, None)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
curved_patch(bm, uv, 0.115, 0.0575, 0.6, 0)
add(finish('opslabs_uniform_badge', bm, [mat('opslabs_uni_chest', 'decal.sps')]), 40.0, None)

# hard hat: ellipsoid shell (wider front-to-back), brim all round with a peak at the front (-Y), centre ridge, sticker
A, B, HH, Z0 = 0.112, 0.132, 0.118, 0.012
def shell_pt(lat, lon, s=1.0):
    return (A * s * math.cos(lat) * math.cos(lon), B * s * math.cos(lat) * math.sin(lon), Z0 + HH * s * math.sin(lat))
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
NL, NA = 10, 36
grid = [[shell_pt(math.radians(90 * i / NL), 2 * math.pi * j / NA) for j in range(NA)] for i in range(NL + 1)]
for i in range(NL):
    for j in range(NA):
        jn = (j + 1) % NA
        face(bm, uv, [grid[i][j], grid[i][jn], grid[i + 1][jn], grid[i + 1][j]], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))
# brim: outward lip, wide peak at the front, slight droop
def brim_out(lon):
    front = max(0.0, -math.sin(lon)) ** 2.5
    return 0.016 + 0.062 * front
inner = [shell_pt(0, 2 * math.pi * j / NA) for j in range(NA)]
outer = []
for j in range(NA):
    lon = 2 * math.pi * j / NA
    e = brim_out(lon)
    outer.append((math.cos(lon) * (A + e), math.sin(lon) * (B + e), Z0 - 0.012 - 0.012 * max(0.0, -math.sin(lon))))
for j in range(NA):
    jn = (j + 1) % NA
    t0, t1 = inner[j], inner[jn]
    o0, o1 = outer[j], outer[jn]
    face(bm, uv, [t0, o0, o1, t1], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))                                         # top of brim
    d = 0.006
    face(bm, uv, [(t1[0], t1[1], t1[2] - d), (o1[0], o1[1], o1[2] - d), (o0[0], o0[1], o0[2] - d), (t0[0], t0[1], t0[2] - d)], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))
    face(bm, uv, [o0, (o0[0], o0[1], o0[2] - d), (o1[0], o1[1], o1[2] - d), o1], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))
# centre ridge front to back over the top
pts = []
for i in range(0, 31):
    t = math.radians(52 + 76 * i / 30)                           # over the crown, front to back
    lat = t if t <= math.pi / 2 else math.pi - t
    lon = math.radians(270) if t <= math.pi / 2 else math.radians(90)
    pts.append(shell_pt(lat, lon, 1.035))
for i in range(len(pts) - 1):
    (x0, y0, z0), (x1, y1, z1) = pts[i], pts[i + 1]
    w = 0.009
    face(bm, uv, [(x0 - w, y0, z0), (x0 + w, y0, z0), (x1 + w, y1, z1), (x1 - w, y1, z1)], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))
    face(bm, uv, [(x0 - w, y0, z0), (x1 - w, y1, z1), (x1 - w, y1 * 0.97, z1 * 0.97), (x0 - w, y0 * 0.97, z0 * 0.97)], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))
    face(bm, uv, [(x0 + w, y0, z0), (x0 + w, y0 * 0.97, z0 * 0.97), (x1 + w, y1 * 0.97, z1 * 0.97), (x1 + w, y1, z1)], 0, ((0, 0), (1, 0), (1, 1), (0, 1)))
# sticker on the front of the dome (decal), clear of the ridge on the wearer's right-front
SL0, SL1, SA0, SA1 = math.radians(12), math.radians(44), math.radians(246), math.radians(294)
n = 8
for i in range(n):
    for j in range(n):
        la0, la1 = SL0 + (SL1 - SL0) * i / n, SL0 + (SL1 - SL0) * (i + 1) / n
        lo0, lo1 = SA0 + (SA1 - SA0) * j / n, SA0 + (SA1 - SA0) * (j + 1) / n
        face(bm, uv, [shell_pt(la0, lo1, 1.004), shell_pt(la0, lo0, 1.004), shell_pt(la1, lo0, 1.004), shell_pt(la1, lo1, 1.004)], 1,
             (((j + 1) / n, i / n), (j / n, i / n), (j / n, (i + 1) / n), ((j + 1) / n, (i + 1) / n)))
add(finish('opslabs_hardhat', bm, [mat('opslabs_uni_shell'), mat('opslabs_uni_hat', 'decal.sps')]), 60.0, None)

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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_van.blend'))
