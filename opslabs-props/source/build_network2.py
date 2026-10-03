"""Exchange, street chambers, underground and customer-internal kit (generic look, no branding):
  exchange racks: OLT, MDF, DSLAM, HOF, FDF, DC power plant + batteries
  street: footway box (JRC4-style), modular chamber, manhole cover
  underground: U-CBT, track joint, base node
  customer internal: master socket (NTE5C style), VDSL faceplate, splicing tray, fibre entry cap
blender -b --python build_network2.py -- <out_dir>      Origin: bottom centre (wall kit: back face), fronts -Y.
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


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


GREEN, AMBER, BLUE, OFF = (60, 220, 90), (255, 170, 40), (60, 160, 255), (50, 52, 56)

# ---------------------------------------------------------------- textures
c = Canvas(64, 64, (52, 55, 60)); c.noise(4); save(c, 'opslabs_rack_body')
c = Canvas(64, 64, (190, 194, 198)); c.noise(6); save(c, 'opslabs_rack_frame')

# OLT: shelves of line cards with port LEDs
c = Canvas(256, 512, (30, 32, 36))
for shelf in range(4):
    y0 = 20 + shelf * 120
    c.rect(10, y0, 246, y0 + 100, (18, 19, 22))
    for card in range(14):
        x = 16 + card * 16
        c.rect(x, y0 + 6, x + 12, y0 + 94, (44, 46, 52))
        for k in range(8):
            c.circle(x + 6, y0 + 16 + k * 10, 2, GREEN if (card + k + shelf) % 5 else AMBER)
c.noise(2); save(c, 'opslabs_olt_front')

# MDF: rows of cream terminal blocks with red / white jumpers
c = Canvas(256, 512, (130, 134, 138))
for row in range(24):
    y = 12 + row * 20
    c.rect(14, y, 242, y + 14, (226, 220, 196))
    for k in range(20):
        c.rect(18 + k * 11, y + 4, 22 + k * 11, y + 10, (190, 150, 60))
for k in range(30):
    x = 20 + (k * 37) % 216
    c.rect(x, 0, x + 2, 512, (200, 40, 40) if k % 2 else (240, 240, 240), 0.7)
c.noise(3); save(c, 'opslabs_mdf_front')

# DSLAM: dense port cards
c = Canvas(256, 512, (36, 38, 42))
for shelf in range(3):
    y0 = 24 + shelf * 160
    for card in range(12):
        x = 14 + card * 19
        c.rect(x, y0, x + 15, y0 + 140, (26, 27, 30))
        for k in range(12):
            c.rect(x + 3, y0 + 8 + k * 11, x + 12, y0 + 15 + k * 11, (12, 12, 14))
        c.circle(x + 7, y0 + 136, 2, GREEN)
c.noise(2); save(c, 'opslabs_dslam_front')

# HOF: blocks with a coloured handover label strip per provider
c = Canvas(256, 512, (120, 124, 128))
cols = [(10, 132, 255), (255, 55, 95), (48, 209, 88), (255, 159, 10)]
for row in range(16):
    y = 14 + row * 30
    c.rect(14, y, 242, y + 22, (226, 220, 196))
    c.rect(14, y, 30, y + 22, cols[row % 4])
    for k in range(18):
        c.rect(36 + k * 11, y + 7, 40 + k * 11, y + 15, (190, 150, 60))
c.noise(3); save(c, 'opslabs_hof_front')

# FDF: patch panels with yellow cords looping down
c = Canvas(256, 512, (34, 36, 40))
for row in range(12):
    y = 16 + row * 40
    c.rect(12, y, 244, y + 24, (22, 23, 26))
    for k in range(24):
        c.rect(16 + k * 9.5, y + 8, 22 + k * 9.5, y + 16, (40, 120, 200) if k % 6 else (40, 170, 90))
for k in range(18):
    x = 20 + k * 12
    c.rect(x, 40, x + 3, 480, (240, 200, 30), 0.85)
c.noise(2); save(c, 'opslabs_fdf_front')

# DC power: rectifier shelf at the top, battery strings below
c = Canvas(256, 512, (40, 42, 46))
c.rect(12, 12, 244, 110, (60, 62, 68))
for k in range(4):
    c.rect(20 + k * 56, 20, 70 + k * 56, 100, (30, 31, 34)); c.circle(45 + k * 56, 90, 3, GREEN)
for row in range(4):
    y = 130 + row * 92
    for k in range(4):
        c.rect(18 + k * 58, y, 70 + k * 58, y + 80, (20, 20, 22))
        c.rect(26 + k * 58, y + 6, 36 + k * 58, y + 14, (200, 40, 40)); c.rect(52 + k * 58, y + 6, 62 + k * 58, y + 14, (30, 30, 30))
c.noise(2); save(c, 'opslabs_dcpower_front')

# chamber lids
c = Canvas(128, 128, (88, 90, 92))
for y in range(6, 128, 12):
    for x in range(6 + (y // 12 % 2) * 6, 128, 12):
        c.rrect(x, y, x + 8, y + 3, 1, (112, 114, 116))
c.rect(0, 0, 128, 4, (50, 50, 52)); c.rect(0, 124, 128, 128, (50, 50, 52)); c.rect(0, 0, 4, 128, (50, 50, 52)); c.rect(124, 0, 128, 128, (50, 50, 52))
c.noise(6); save(c, 'opslabs_lid_iron')
c = Canvas(128, 128, (70, 72, 70))
for r in range(10, 64, 9):
    c.circle(64, 64, r, (90, 92, 90)); c.circle(64, 64, r - 3, (70, 72, 70))
c.noise(6); save(c, 'opslabs_manhole_lid')
c = Canvas(64, 64, (150, 148, 140)); c.noise(10); save(c, 'opslabs_concrete')
c = Canvas(64, 64, (24, 24, 26)); c.noise(3); save(c, 'opslabs_black')
c = Canvas(64, 64, (242, 242, 240)); c.noise(2); save(c, 'opslabs_white')
# master socket face: test socket + phone socket
c = Canvas(128, 128, (244, 244, 242))
c.rrect(28, 30, 100, 64, 4, (200, 200, 198)); c.rect(52, 40, 76, 54, (40, 40, 42))
c.rrect(40, 76, 88, 108, 4, (210, 210, 208)); c.rect(56, 84, 72, 100, (40, 40, 42))
c.noise(2); save(c, 'opslabs_nte5c_face')
c = Canvas(128, 128, (244, 244, 242))
c.rect(30, 50, 54, 64, (40, 40, 42)); c.rect(74, 50, 98, 64, (40, 40, 42)); c.noise(2); save(c, 'opslabs_vdsl_face')

MATS = {}


def mat(name):
    if name in MATS:
        return MATS[name]
    m = sz_mats.create_shader('default.sps')
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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, top=None):
    F = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    for k, vs in F.items():
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        m = front if k == 'front' and front is not None else top if k == 'top' and top is not None else mi
        f.material_index = m
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


def cyl(bm, uv, p0, p1, r, sides=12, mi=0, cap_mi=None):
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
        f.smooth = True
        for loop, uvv in zip(f.loops, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, 1), (i / sides, 1))):
            loop[uv].uv = uvv
    for k, ring in enumerate(rings):
        f = bm.faces.new(ring if k else list(reversed(ring)))
        f.material_index = mi if cap_mi is None else cap_mi
        for loop in f.loops:
            co = loop.vert.co
            loop[uv].uv = (0.5 + (co - (b if k else a)).dot(u) / (2 * r), 0.5 + (co - (b if k else a)).dot(w) / (2 * r))


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- exchange racks: 600 x 600 x 2200 frames with a front panel per type
for name, tex in (('opslabs_olt', 'opslabs_olt_front'), ('opslabs_mdf', 'opslabs_mdf_front'), ('opslabs_dslam', 'opslabs_dslam_front'),
                  ('opslabs_hof', 'opslabs_hof_front'), ('opslabs_fdf', 'opslabs_fdf_front'), ('opslabs_dc_power', 'opslabs_dcpower_front')):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -0.30, -0.30, 0.0, 0.30, 0.30, 2.2, mi=0, front=1)
    for x in (-0.30, 0.27):                                                      # front frame uprights
        box(bm, uv, x, -0.31, 0.0, x + 0.03, -0.29, 2.2, mi=2)
    box(bm, uv, -0.30, -0.31, 2.17, 0.30, -0.29, 2.2, mi=2)
    add(finish(name, bm, [mat('opslabs_rack_body'), mat(tex), mat('opslabs_rack_frame')]), 60.0, 'METAL_SOLID_MEDIUM')

# --- street chambers (flush with the ground; frame + lid)
for name, W, D, tex in (('opslabs_footway_box', 0.68, 0.44, 'opslabs_lid_iron'), ('opslabs_chamber_modular', 1.30, 0.70, 'opslabs_lid_iron')):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -W / 2 - 0.05, -D / 2 - 0.05, -0.02, W / 2 + 0.05, D / 2 + 0.05, 0.008, mi=1)   # concrete surround
    if W > 1:
        box(bm, uv, -W / 2, -D / 2, 0.008, -0.01, D / 2, 0.014, mi=0, top=0)
        box(bm, uv, 0.01, -D / 2, 0.008, W / 2, D / 2, 0.014, mi=0, top=0)
    else:
        box(bm, uv, -W / 2, -D / 2, 0.008, W / 2, D / 2, 0.014, mi=0, top=0)
    add(finish(name, bm, [mat(tex), mat('opslabs_concrete')]), 60.0, 'METAL_SOLID_SMALL')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, -0.02), (0, 0, 0.008), 0.56, sides=28, mi=1)
cyl(bm, uv, (0, 0, 0.008), (0, 0, 0.016), 0.46, sides=28, mi=0, cap_mi=0)
add(finish('opslabs_manhole', bm, [mat('opslabs_manhole_lid'), mat('opslabs_concrete')]), 60.0, 'METAL_SOLID_SMALL')

# --- underground kit (sits on the ground / in a chamber)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')                         # U-CBT: squat sealed manifold
cyl(bm, uv, (0, 0, 0.0), (0, 0, 0.22), 0.09, sides=18, mi=0)
for k in range(8):
    a = 2 * math.pi * k / 8
    cyl(bm, uv, (0.09 * math.cos(a), 0.09 * math.sin(a), 0.06), (0.12 * math.cos(a), 0.12 * math.sin(a), 0.06), 0.012, sides=8, mi=1)
add(finish('opslabs_ucbt', bm, [mat('opslabs_black'), mat('opslabs_rack_frame')]), 60.0, 'PLASTIC')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')                         # track joint: long canister lying down
cyl(bm, uv, (-0.35, 0, 0.11), (0.35, 0, 0.11), 0.11, sides=20, mi=0)
for x in (-0.36, 0.36):
    cyl(bm, uv, (x, 0, 0.11), (x + (0.06 if x > 0 else -0.06), 0, 0.11), 0.04, sides=12, mi=0)
for x in (-0.2, 0.2):
    cyl(bm, uv, (x - 0.01, 0, 0.11), (x + 0.01, 0, 0.11), 0.115, sides=20, mi=1)
add(finish('opslabs_track_joint', bm, [mat('opslabs_black'), mat('opslabs_rack_frame')]), 60.0, 'PLASTIC')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')                         # base node: tall dome manifold
cyl(bm, uv, (0, 0, 0.0), (0, 0, 0.45), 0.13, sides=20, mi=0)
for k in range(6):
    a = 2 * math.pi * k / 6
    cyl(bm, uv, (0.13 * math.cos(a), 0.13 * math.sin(a), 0.1), (0.17 * math.cos(a), 0.17 * math.sin(a), 0.1), 0.016, sides=8, mi=1)
add(finish('opslabs_base_node', bm, [mat('opslabs_black'), mat('opslabs_rack_frame')]), 60.0, 'PLASTIC')

# --- customer internal (wall-mounted, origin = back face, front -Y)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.043, -0.035, 0.0, 0.043, 0.0, 0.086, mi=0, front=1)
add(finish('opslabs_nte5c', bm, [mat('opslabs_white'), mat('opslabs_nte5c_face')]), 25.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.043, -0.045, 0.0, 0.043, 0.0, 0.086, mi=0, front=1)
add(finish('opslabs_vdsl_faceplate', bm, [mat('opslabs_white'), mat('opslabs_vdsl_face')]), 25.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.09, -0.03, 0.0, 0.09, 0.0, 0.13, mi=0)
box(bm, uv, -0.07, -0.032, 0.02, 0.07, -0.03, 0.11, mi=1)
add(finish('opslabs_splice_tray', bm, [mat('opslabs_white'), mat('opslabs_rack_body')]), 25.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0.0, 0.03), (0, -0.018, 0.03), 0.032, sides=16, mi=0)
add(finish('opslabs_entry_cap', bm, [mat('opslabs_white')]), 25.0)

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
ytyp.name = 'opslabs_network2_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_network2.blend'))
