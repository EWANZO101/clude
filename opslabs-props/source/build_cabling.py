"""CAT6 cabling props: cable segments + joint, cable pull-box, RJ45 plug, trunking (blue/black/white).
blender -b --python build_cabling.py -- <out_dir>

Conventions (all models): run along +Y from the origin, local +Z = away from the surface.
  cable   : round, centred on the Y axis (lifted onto the surface in game)
  trunking: base sits on z = 0
"""
import math
import os
import struct
import sys

import bmesh
import bpy

OUT = sys.argv[sys.argv.index('--') + 1]
TEX = os.path.join(OUT, 'tex')
os.makedirs(TEX, exist_ok=True)

addon = 'bl_ext.user_default.sollumz'
import addon_utils  # noqa: E402
addon_utils.enable(addon, default_set=True)
from importlib import import_module  # noqa: E402
sz_mats = import_module(addon + '.ydr.shader_materials')
sz_col = import_module(addon + '.ybn.collision_materials')

exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'canvas_lib.py')).read())  # Canvas, write helpers

# ---------------------------------------------------------------------------
# textures
# ---------------------------------------------------------------------------

# cable jacket: matte black, faint grey print marks along the length
C = Canvas(16, 256, (14, 14, 15))
for y in range(0, 256, 64):
    for k in range(5):
        C.rect(6, y + 8 + k * 7, 10, y + 12 + k * 7, (70, 70, 72))
C.noise(2)
C.save_dds(os.path.join(TEX, 'opslabs_cat6_jacket.dds'))

# trunking colours (moulded PVC, lid seam line in the middle of the top)
TRUNK = {'blue': (40, 90, 190), 'black': (24, 24, 26), 'white': (236, 237, 235), 'capping': (150, 154, 158), 'capping25': (226, 228, 224), 'subduct': (236, 110, 20), 'bft': (40, 150, 70)}
TUBES = {'subduct': 0.016, 'bft': 0.008}   # round ducts: radius; base sits on the surface
for name, col in TRUNK.items():
    T = Canvas(64, 64, col)
    seam = tuple(max(0, c - 40) for c in col) if name != 'black' else (60, 60, 64)
    T.rect(31, 0, 33, 64, seam)
    T.noise(2)
    T.save_dds(os.path.join(TEX, f'opslabs_trunk_{name}.dds'))

# cardboard box with blue print: "CAT6" + "305M" in block letters
FONT = {
    'C': ['01110', '10001', '10000', '10000', '10000', '10001', '01110'],
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'],
    '6': ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
    '3': ['11110', '00001', '00001', '01110', '00001', '00001', '11110'],
    '0': ['01110', '10011', '10101', '10101', '11001', '10001', '01110'],
    '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
    'M': ['10001', '11011', '10101', '10101', '10001', '10001', '10001'],
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


BOX = Canvas(256, 256, (178, 140, 96))
BOX.noise(6)
BOX.rect(0, 0, 256, 34, (30, 90, 180))
BOX.rect(0, 222, 256, 256, (30, 90, 180))
text(BOX, 'CAT6', 40, 70, 8, (30, 90, 180))
text(BOX, '305M', 40, 150, 8, (30, 90, 180))
BOX.save_dds(os.path.join(TEX, 'opslabs_cat6_box.dds'))

# RJ45 plug: clear-ish plastic with gold contacts at the tip (texture along Y)
P = Canvas(32, 64, (205, 210, 215))
for i in range(8):
    P.rect(2 + i * 3.6, 0, 3.6 + i * 3.6, 10, (200, 160, 60))
P.rect(0, 40, 32, 64, (18, 18, 20))   # boot
P.save_dds(os.path.join(TEX, 'opslabs_rj45.dds'))


def material(shader, dds):
    mat = sz_mats.create_shader(shader)
    mat.name = os.path.splitext(dds)[0]
    img = bpy.data.images.load(os.path.join(TEX, dds), check_existing=True)
    img.name = os.path.splitext(dds)[0]
    for node in mat.node_tree.nodes:
        if isinstance(node, bpy.types.ShaderNodeTexImage) and node.name == 'DiffuseSampler':
            node.image = img
            node.texture_properties.embedded = True
    return mat


MAT = {
    'jacket': material('default.sps', 'opslabs_cat6_jacket.dds'),
    'box': material('default.sps', 'opslabs_cat6_box.dds'),
    'rj45': material('default.sps', 'opslabs_rj45.dds'),
}
for name in TRUNK:
    MAT['trunk_' + name] = material('default.sps', f'opslabs_trunk_{name}.dds')

# ---------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)

R = 0.004  # cable radius (8 mm CAT6)


def finish_mesh(name, bm, mats, smooth=False):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    col = me.color_attributes.new('Color 1', 'BYTE_COLOR', 'CORNER')
    for d in col.data:
        d.color = (1, 1, 1, 1)
    for p in me.polygons:
        p.use_smooth = smooth
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def tube(bm, uv, length, radius, sides=10, y0=0.0, mat=0, v_per_m=4.0, caps=True):
    """cylinder along +Y, UV wraps around and repeats along the length"""
    rings = []
    for k, y in enumerate((y0, y0 + length)):
        ring = []
        for i in range(sides):
            a = 2 * math.pi * i / sides
            ring.append(bm.verts.new((radius * math.cos(a), y, radius * math.sin(a))))
        rings.append(ring)
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
        f.material_index = mat
        f.smooth = True
        us = (i / sides, (i + 1) / sides)
        for loop, (u, v) in zip(f.loops, ((us[0], 0), (us[1], 0), (us[1], length * v_per_m), (us[0], length * v_per_m))):
            loop[uv].uv = (u, v)
    if caps:
        for k, ring in enumerate(rings):
            f = bm.faces.new(ring if k else list(reversed(ring)))
            f.material_index = mat
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.1)
    return rings


def quadf(bm, uv, vs, mat, uvs=((0, 0), (1, 0), (1, 1), (0, 1))):
    f = bm.faces.new([bm.verts.new(v) for v in vs])
    f.material_index = mat
    for loop, u in zip(f.loops, uvs):
        loop[uv].uv = u
    return f


def boxm(bm, uv, x0, y0, z0, x1, y1, z1, mat, scale=1.0, skip=(), full=False):
    sx, sy, sz = (x1 - x0) * scale, (y1 - y0) * scale, (z1 - z0) * scale
    if full:
        sx = sy = sz = 1.0
    faces = {
        'y0': ([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (sx, sz)),
        'y1': ([(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], (sx, sz)),
        'x0': ([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], (sy, sz)),
        'x1': ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], (sy, sz)),
        'z1': ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (sx, sy)),
        'z0': ([(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], (sx, sy)),
    }
    for k, (vs, (u, v)) in faces.items():
        if k not in skip:
            quadf(bm, uv, vs, mat, ((0, 0), (u, 0), (u, v), (0, v)))


models = []   # (object, lod, collision material or None)

# cable segments
for cm in (5, 10, 25, 50, 100, 200):
    L = cm / 100
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    tube(bm, uv, L, R, sides=10)
    models.append((finish_mesh(f'opslabs_cat6_seg_{cm:03d}', bm, [MAT['jacket']], smooth=True), 30.0, None))

# joint (small ball that hides gaps at corners)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
bmesh.ops.create_uvsphere(bm, u_segments=10, v_segments=6, radius=R * 1.02)
for f in bm.faces:
    f.smooth = True
    for loop in f.loops:
        loop[uv].uv = (0.5, 0.05)
models.append((finish_mesh('opslabs_cat6_joint', bm, [MAT['jacket']], smooth=True), 30.0, None))

# pull-box 350 x 350 x 220 mm with a cable stub coming out of the top
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
boxm(bm, uv, -0.175, -0.175, 0.0, 0.175, 0.175, 0.22, 0, full=True)
# pull-out hole (dark disc) + the cable end standing out of it, near the front of the lid
start = len(bm.verts)
hole = bmesh.ops.create_circle(bm, cap_ends=True, segments=12, radius=0.012)
for v in hole['verts']:
    v.co = (v.co.x, v.co.y - 0.10, 0.2203)
for f in bm.faces[-1:]:
    f.material_index = 1
    for loop in f.loops:
        loop[uv].uv = (0.5, 0.05)
start = len(bm.verts)
tube(bm, uv, 0.07, R, sides=10, y0=0.0, mat=1)
bm.verts.ensure_lookup_table()
for v in bm.verts[start:]:
    x, y, z = v.co
    v.co = (x, -0.10 + z, 0.2203 + y)
models_box = finish_mesh('opslabs_cat6_box', bm, [MAT['box'], MAT['jacket']])
models.append((models_box, 60.0, 'CARDBOARD'))

# RJ45 plug + boot, tip at the origin pointing -Y (into the port), cable leaves along +Y
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
boxm(bm, uv, -0.0058, 0.0, -0.0040, 0.0058, 0.021, 0.0040, 0, scale=0.0)
for f in bm.faces:
    for loop in f.loops:
        co = loop.vert.co
        loop[uv].uv = ((co.x + 0.0058) / 0.0116, co.y / 0.021 * (40 / 64))
boot = tube(bm, uv, 0.018, 0.0045, sides=10, y0=0.021, mat=0)
for ring in boot:
    for v in ring:
        pass
tube(bm, uv, 0.03, R, sides=10, y0=0.039, mat=1)
plug = finish_mesh('opslabs_rj45_plug', bm, [MAT['rj45'], MAT['jacket']])
for f in plug.data.polygons:
    pass
models.append((plug, 25.0, None))

# trunking 25 x 16 mm, lengths + corner block, in three colours
TW, TH = 0.025, 0.016
for name in TRUNK:
    mi = 0
    if name in TUBES:
        R = TUBES[name]
        for cm in (25, 50, 100, 200):
            L = cm / 100
            bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
            rings = tube(bm, uv, L, R, sides=12)
            bm.verts.ensure_lookup_table()
            for v in bm.verts:
                v.co.z += R                       # sit on the surface like trunking does
            models.append((finish_mesh(f'opslabs_trunk_{name}_{cm:03d}', bm, [MAT['trunk_' + name]], smooth=True), 50.0, None))
        bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
        bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=8, radius=R * 1.05)
        for f in bm.faces:
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.5)
        for v in bm.verts:
            v.co.z += R
        models.append((finish_mesh(f'opslabs_trunk_{name}_corner', bm, [MAT['trunk_' + name]], smooth=True), 50.0, None))
        continue
    for cm in (25, 50, 100, 200):
        L = cm / 100
        bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
        boxm(bm, uv, -TW / 2, 0.0, 0.0, TW / 2, L, TH, mi, scale=1.0 / 0.064 * 0.064 / TW)
        # small lip lines along the lid edges (slightly proud strips)
        boxm(bm, uv, -TW / 2 - 0.0008, 0.0, TH - 0.002, -TW / 2, L, TH, mi)
        boxm(bm, uv, TW / 2, 0.0, TH - 0.002, TW / 2 + 0.0008, L, TH, mi)
        models.append((finish_mesh(f'opslabs_trunk_{name}_{cm:03d}', bm, [MAT['trunk_' + name]]), 50.0, None))
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    boxm(bm, uv, -TW / 2 - 0.0012, -TW / 2 - 0.0012, 0.0, TW / 2 + 0.0012, TW / 2 + 0.0012, TH + 0.0012, mi, scale=1.0 / TW)
    models.append((finish_mesh(f'opslabs_trunk_{name}_corner', bm, [MAT['trunk_' + name]]), 50.0, None))

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
        cmat = sz_col.create_collision_material_from_index(idx)
        for child in d.children_recursive:
            if child.type == 'MESH' and 'poly_mesh' in child.name:
                child.data.materials.clear()
                child.data.materials.append(cmat)
print('DRAWABLES', len(drawables))

bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_cabling_props'
bpy.ops.object.select_all(action='DESELECT')
for d, _ in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0][0]
bpy.ops.sollumz.createarchetypefromselected()
lods = {d.name: lod for d, lod in drawables}
for a in ytyp.archetypes:
    a.lod_dist = lods.get(a.name, 40.0)
print('ARCHETYPES', len(ytyp.archetypes))

res = bpy.ops.sollumz.export_assets(
    directory=OUT, direct_export=True, use_custom_settings=True,
    target_formats={'CWXML'}, target_versions={'GEN8'},
    limit_to_selected=False, export_ytyps=True,
)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_cabling.blend'))
