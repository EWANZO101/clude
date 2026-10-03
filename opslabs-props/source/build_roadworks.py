"""Road works safety kit (generic UK-style street works look, no operator branding):
  traffic cone, pedestrian barriers ("FIBRE WORKS IN PROGRESS" / "STAY BACK"), temporary sign
  on a stand (8 variants, each with its own face texture so the text can be drawn live per sign),
  portable traffic light + lamp discs, cordon tape between posts.
blender -b --python build_roadworks.py -- <out_dir>      Origin: bottom centre, fronts face -Y.
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
    'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'], 'B': ['11110', '10001', '10001', '11110', '10001', '10001', '11110'],
    'C': ['01110', '10001', '10000', '10000', '10000', '10001', '01110'], 'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'],
    'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'], 'F': ['11111', '10000', '10000', '11110', '10000', '10000', '10000'],
    'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01111'], 'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
    'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'], 'K': ['10001', '10010', '10100', '11000', '10100', '10010', '10001'],
    'L': ['10000', '10000', '10000', '10000', '10000', '10000', '11111'], 'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'],
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], 'P': ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
    'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'], 'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'],
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], 'U': ['10001', '10001', '10001', '10001', '10001', '10001', '01110'],
    'W': ['10001', '10001', '10001', '10101', '10101', '10101', '01010'], 'Y': ['10001', '10001', '01010', '00100', '00100', '00100', '00100'],
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


def centered(c, s, y, px, color):
    w = len(s) * 6 * px - px
    text(c, s, (c.w - w) // 2, y, px, color)


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


RED, WHITE, YELLOW, BLACK, ORANGE = (200, 28, 32), (244, 244, 240), (250, 214, 30), (20, 20, 22), (240, 96, 20)

# cone: orange with a white reflective band
c = Canvas(64, 128, ORANGE)
c.rect(0, 40, 64, 64, WHITE); c.noise(3); save(c, 'opslabs_rw_cone')
c = Canvas(64, 128, ORANGE)
c.rect(0, 28, 64, 44, WHITE); c.rect(0, 58, 64, 74, WHITE); c.noise(3); save(c, 'opslabs_rw_cone2')
c = Canvas(32, 32, BLACK); c.noise(3); save(c, 'opslabs_rw_black')
# barrier rails: red / white blocks
c = Canvas(256, 32, WHITE)
for x in range(0, 256, 64):
    c.rect(x, 0, x + 32, 32, RED)
c.noise(2); save(c, 'opslabs_rw_rail')
# barrier boards
for name, lines in (('opslabs_rw_board_works', ('FIBRE WORKS', 'IN PROGRESS')), ('opslabs_rw_board_stay', ('STAY BACK', 'FIBRE WORKS'))):
    c = Canvas(512, 128, WHITE)
    c.rect(0, 0, 512, 10, RED); c.rect(0, 118, 512, 128, RED)
    centered(c, lines[0], 22, 6, RED if 'STAY' in lines[0] else BLACK)
    centered(c, lines[1], 72, 5, BLACK)
    c.noise(2); save(c, name)
# sign faces (default text; replaced live per sign in game)
for n in range(1, 9):
    c = Canvas(256, 192, YELLOW)
    c.rect(0, 0, 256, 8, RED); c.rect(0, 184, 256, 192, RED); c.rect(0, 0, 8, 192, RED); c.rect(248, 0, 256, 192, RED)
    centered(c, 'FIBRE WORKS', 40, 3, BLACK)
    centered(c, 'IN PROGRESS', 80, 3, BLACK)
    c.noise(2); save(c, f'opslabs_rw_signface_{n}')
c = Canvas(64, 64, (150, 154, 158)); c.noise(8); save(c, 'opslabs_rw_metal')
c = Canvas(64, 64, (38, 38, 40)); c.noise(4); save(c, 'opslabs_rw_rubber')
# traffic light head: black with yellow backboard edge
c = Canvas(64, 192, BLACK)
c.rect(0, 0, 64, 6, YELLOW); c.rect(0, 186, 64, 192, YELLOW); c.rect(0, 0, 6, 192, YELLOW); c.rect(58, 0, 64, 192, YELLOW)
for k in range(3):
    c.circle(32, 32 + k * 64, 22, (28, 28, 30)); c.circle(32, 32 + k * 64, 18, (55, 55, 58))
save(c, 'opslabs_rw_head')
for name, col in (('opslabs_rw_lamp_red', (255, 40, 30)), ('opslabs_rw_lamp_amber', (255, 170, 20)), ('opslabs_rw_lamp_green', (40, 255, 120))):
    c = Canvas(32, 32, col); c.circle(16, 16, 10, tuple(min(255, v + 60) for v in col)); save(c, name)
# cordon tape: red / white with text
c = Canvas(512, 32, WHITE)
for x in range(0, 512, 128):
    c.rect(x, 0, x + 64, 32, RED)
text(c, 'STAY BACK', 70, 9, 2, BLACK); text(c, 'STAY BACK', 326, 9, 2, BLACK)
save(c, 'opslabs_rw_tape')

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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, back=None):
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
        f.material_index = {'front': front, 'back': back}.get(k) if {'front': front, 'back': back}.get(k) is not None else mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


def ring_stack(bm, uv, profile, sides=16, mi=0, cx=0.0, cy=0.0):
    """lathe: profile = [(radius, z, v)] bottom→top"""
    rings = []
    for r, z, v in profile:
        rings.append([bm.verts.new((cx + r * math.cos(2 * math.pi * i / sides), cy + r * math.sin(2 * math.pi * i / sides), z)) for i in range(sides)])
    for k in range(len(rings) - 1):
        for i in range(sides):
            j = (i + 1) % sides
            f = bm.faces.new((rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]))
            f.material_index = mi
            f.smooth = True
            for loop, u in zip(f.loops, ((i / sides, profile[k][2]), (j / sides, profile[k][2]), (j / sides, profile[k + 1][2]), (i / sides, profile[k + 1][2]))):
                loop[uv].uv = u
    return rings


def cyl(bm, uv, p0, p1, r, sides=8, mi=0):
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
        f.material_index = mi
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)


models = []   # (obj, lod, collision)

# --- cones: 450 mm (small), 750 mm (standard), 1 m (large, two reflective bands)
def cone(name, H, base, tex):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -base / 2, -base / 2, 0.0, base / 2, base / 2, 0.035 * H / 0.75, mi=1)
    k = H / 0.75
    ring_stack(bm, uv, [(0.15 * k, 0.035 * k, 0.0), (0.12 * k, 0.25 * k, 0.3), (0.075 * k, 0.5 * k, 0.65), (0.03 * k, 0.74 * k, 0.98), (0.0, 0.75 * k, 1.0)], sides=16, mi=0)
    models.append((finish(name, bm, [mat(tex), mat('opslabs_rw_black')]), 80.0, 'PLASTIC'))


cone('opslabs_rw_cone_450', 0.45, 0.25, 'opslabs_rw_cone')
cone('opslabs_rw_cone', 0.75, 0.38, 'opslabs_rw_cone')
cone('opslabs_rw_cone_1000', 1.0, 0.48, 'opslabs_rw_cone2')

# --- pedestrian barriers 2.0 x 1.0 m
for name, board in (('opslabs_rw_barrier', 'opslabs_rw_board_works'), ('opslabs_rw_barrier_stay', 'opslabs_rw_board_stay')):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    for x in (-0.98, 0.98):
        box(bm, uv, x - 0.02, -0.02, 0.0, x + 0.02, 0.02, 1.0, mi=1)        # uprights
        box(bm, uv, x - 0.05, -0.25, 0.0, x + 0.05, 0.25, 0.05, mi=3)       # rubber feet
    box(bm, uv, -0.98, -0.012, 0.82, 0.98, 0.012, 0.98, mi=0)               # top rail
    box(bm, uv, -0.96, -0.010, 0.30, 0.96, 0.010, 0.70, mi=1, front=2, back=2)  # sign board
    box(bm, uv, -0.98, -0.012, 0.12, 0.98, 0.012, 0.22, mi=0)               # lower rail
    models.append((finish(name, bm, [mat('opslabs_rw_rail'), mat('opslabs_rw_metal'), mat(board), mat('opslabs_rw_rubber')]), 100.0, 'PLASTIC'))

# --- temporary sign on a stand: 900 x 675 face at 0.5 m, sandbag feet. 8 variants = 8 live faces
for n in range(1, 9):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    for x in (-0.38, 0.38):
        box(bm, uv, x - 0.015, -0.015, 0.0, x + 0.015, 0.015, 1.2, mi=1)
        box(bm, uv, x - 0.06, -0.35, 0.0, x + 0.06, 0.35, 0.025, mi=1)
        box(bm, uv, x - 0.09, 0.22, 0.025, x + 0.09, 0.38, 0.09, mi=2)      # sandbag
    box(bm, uv, -0.45, -0.03, 0.50, 0.45, -0.018, 1.175, mi=1, front=0)
    models.append((finish(f'opslabs_rw_sign_{n}', bm, [mat(f'opslabs_rw_signface_{n}'), mat('opslabs_rw_metal'), mat('opslabs_rw_rubber')]), 100.0, 'METAL_SOLID_SMALL'))

# --- portable traffic light: trolley, 2.7 m post, signal head with 3 aspects facing -Y
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.35, -0.30, 0.0, 0.35, 0.30, 0.25, mi=2)                     # battery box
cyl(bm, uv, (-0.38, 0.22, 0.09), (0.38, 0.22, 0.09), 0.09, sides=12, mi=3)   # wheels / axle
box(bm, uv, -0.03, -0.03, 0.25, 0.03, 0.03, 2.30, mi=1)                     # post
box(bm, uv, -0.16, -0.12, 2.30, 0.16, 0.0, 3.00, mi=1, front=0)            # head (lenses on front)
for k in range(3):                                                           # visors
    z = 2.93 - k * 0.23
    box(bm, uv, -0.10, -0.20, z, 0.10, -0.12, z + 0.015, mi=3)
models.append((finish('opslabs_rw_tlight', bm, [mat('opslabs_rw_head'), mat('opslabs_rw_metal'), mat('opslabs_rw_rubber'), mat('opslabs_rw_black')]), 150.0, 'METAL_SOLID_SMALL'))
for col in ('red', 'amber', 'green'):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    cyl(bm, uv, (0, 0.0, 0), (0, -0.01, 0), 0.075, sides=16, mi=0)
    models.append((finish('opslabs_rw_lamp_' + col, bm, [mat('opslabs_rw_lamp_' + col, 'emissive.sps')]), 150.0, None))

# --- cordon tape between two posts, 3 m
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
for x in (-1.5, 1.5):
    box(bm, uv, x - 0.02, -0.02, 0.0, x + 0.02, 0.02, 1.0, mi=1)
    ring_stack(bm, uv, [(0.16, 0.0, 0.0), (0.16, 0.05, 0.2), (0.0, 0.06, 0.3)], sides=12, mi=2, cx=x)
f = bm.faces.new([bm.verts.new(v) for v in ((-1.5, -0.002, 0.85), (1.5, -0.002, 0.85), (1.5, -0.002, 0.92), (-1.5, -0.002, 0.92))])
f.material_index = 0
for loop, u in zip(f.loops, ((0, 0), (3, 0), (3, 1), (0, 1))):
    loop[uv].uv = u
f = bm.faces.new([bm.verts.new(v) for v in ((1.5, 0.002, 0.85), (-1.5, 0.002, 0.85), (-1.5, 0.002, 0.92), (1.5, 0.002, 0.92))])
f.material_index = 0
for loop, u in zip(f.loops, ((0, 0), (3, 0), (3, 1), (0, 1))):
    loop[uv].uv = u
models.append((finish('opslabs_rw_tape', bm, [mat('opslabs_rw_tape'), mat('opslabs_rw_metal'), mat('opslabs_rw_black')]), 80.0, None))

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
ytyp.name = 'opslabs_roadworks_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_roadworks.blend'))
