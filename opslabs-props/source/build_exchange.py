"""Telephone exchange: a walk-in single-storey building plus its plant.
  opslabs_exchange_building  16 x 10 x 5 m brick shell, open doorway, windows, raised floor,
                             ceiling light panels, sign over the door. Origin: centre of the floor.
  opslabs_core_router        core router / backhaul switch rack
  opslabs_rectifier          DC rectifier rack (48 V)
  opslabs_battery_bank       industrial battery bank (two-tier stand)
  opslabs_generator          standby diesel generator (outdoor, containerised)
  opslabs_crac               HVAC indoor cooling unit (CRAC)
  opslabs_condenser          HVAC outdoor condenser
blender -b --python build_exchange.py -- <out_dir>      Fronts face -Y.
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
    'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'], 'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'],
    'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'], 'X': ['10001', '01010', '00100', '00100', '00100', '01010', '10001'],
    'C': ['01110', '10001', '10000', '10000', '10000', '10001', '01110'], 'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01111'], ' ': ['00000'] * 7,
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
rnd = random.Random(3)
# brick
c = Canvas(256, 256, (150, 74, 52))
for row in range(0, 256, 16):
    off = 0 if (row // 16) % 2 == 0 else 16
    for x in range(-16 + off, 256, 32):
        sh = rnd.randint(-14, 12)
        c.rect(x + 1, row + 1, x + 31, row + 15, (150 + sh, 74 + sh // 2, 52 + sh // 3))
c.noise(5); save(c, 'opslabs_ex_brick')
c = Canvas(64, 64, (232, 232, 226)); c.noise(3); save(c, 'opslabs_ex_wall')                 # painted interior
c = Canvas(128, 128, (190, 192, 190))                                                        # raised floor tiles
for k in range(0, 128, 32):
    c.rect(k, 0, k + 2, 128, (150, 152, 150)); c.rect(0, k, 128, k + 2, (150, 152, 150))
c.noise(3); save(c, 'opslabs_ex_floor')
c = Canvas(64, 64, (70, 72, 74)); c.noise(6); save(c, 'opslabs_ex_roof')
c = Canvas(64, 64, (40, 52, 66)); c.rect(30, 0, 34, 64, (90, 92, 96)); c.noise(2); save(c, 'opslabs_ex_glass')
c = Canvas(32, 32, (250, 250, 240)); save(c, 'opslabs_ex_light')
c = Canvas(512, 64, (24, 60, 120))
text(c, 'TELEPHONE EXCHANGE', 22, 12, 4, (255, 255, 255)); c.noise(2); save(c, 'opslabs_ex_sign')
c = Canvas(64, 64, (52, 55, 60)); c.noise(4); save(c, 'opslabs_ex_rack')
c = Canvas(64, 64, (190, 194, 198)); c.noise(6); save(c, 'opslabs_ex_metal')
# core router front: line cards, 100G ports, status LEDs
c = Canvas(256, 512, (26, 28, 32))
for slot in range(10):
    y0 = 20 + slot * 46
    c.rect(10, y0, 246, y0 + 40, (40, 42, 48))
    for k in range(16):
        c.rect(16 + k * 14, y0 + 8, 26 + k * 14, y0 + 22, (12, 12, 14))
        c.circle(21 + k * 14, y0 + 30, 2, (60, 220, 90) if (k + slot) % 4 else (60, 160, 255))
c.noise(2); save(c, 'opslabs_ex_router_front')
# rectifier front: modules with displays
c = Canvas(256, 512, (60, 62, 68))
for row in range(6):
    for k in range(3):
        x, y = 16 + k * 78, 20 + row * 80
        c.rect(x, y, x + 70, y + 70, (36, 38, 42)); c.rect(x + 10, y + 10, x + 60, y + 30, (40, 140, 90)); c.circle(x + 35, y + 52, 4, (60, 220, 90))
c.noise(2); save(c, 'opslabs_ex_rectifier_front')
c = Canvas(128, 64, (30, 30, 32))                                                              # battery block
c.rect(8, 6, 28, 14, (200, 40, 40)); c.rect(100, 6, 120, 14, (40, 40, 40)); c.noise(3); save(c, 'opslabs_ex_battery')
c = Canvas(256, 128, (40, 92, 60))                                                              # generator container
for x in range(20, 236, 12):
    c.rect(x, 20, x + 6, 108, (30, 70, 46))
c.noise(4); save(c, 'opslabs_ex_generator')
c = Canvas(128, 256, (236, 238, 236))                                                           # CRAC unit
for y in range(20, 120, 8):
    c.rect(14, y, 114, y + 4, (200, 202, 200))
c.rect(40, 160, 88, 190, (30, 34, 40)); c.rect(46, 166, 82, 184, (60, 200, 230)); c.noise(2); save(c, 'opslabs_ex_crac')
c = Canvas(128, 128, (210, 212, 210)); c.circle(64, 64, 52, (40, 42, 46)); c.circle(64, 64, 10, (150, 152, 150)); c.noise(3); save(c, 'opslabs_ex_fan')

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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, tile=None):
    """tile = metres per texture repeat (world-scaled UVs for walls / floors)"""
    F = {
        'front': ([(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)], (x1 - x0, z1 - z0)),
        'back': ([(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)], (x1 - x0, z1 - z0)),
        'left': ([(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)], (y1 - y0, z1 - z0)),
        'right': ([(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)], (y1 - y0, z1 - z0)),
        'top': ([(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)], (x1 - x0, y1 - y0)),
        'bottom': ([(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)], (x1 - x0, y1 - y0)),
    }
    for k, (vs, (w, h)) in F.items():
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = front if (k == 'front' and front is not None) else mi
        uu, vv = (w / tile, h / tile) if tile else (1, 1)
        for loop, u in zip(f.loops, ((0, 0), (uu, 0), (uu, vv), (0, vv))):
            loop[uv].uv = u


def cyl(bm, uv, p0, p1, r, sides=12, mi=0):
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
        f.material_index = mi
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- the exchange building: 16 x 10 m footprint, 5 m tall, 0.3 m walls; door in the middle of the
#     front (-Y) wall, windows along the sides. Materials: 0 brick, 1 painted wall, 2 floor, 3 roof,
#     4 glass, 5 light panel (emissive), 6 sign
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H, T = 16.0, 10.0, 5.0, 0.3
hx, hy = W / 2, D / 2
box(bm, uv, -hx, -hy, -0.2, hx, hy, 0.15, mi=2, tile=2.0)                                     # slab + raised floor
box(bm, uv, -hx - 0.2, -hy - 0.2, H, hx + 0.2, hy + 0.2, H + 0.35, mi=3, tile=4.0)          # flat roof
box(bm, uv, -hx, hy - T, 0.0, hx, hy, H, mi=0, tile=2.0)                                      # back wall
for sx in (-1, 1):                                                                            # side walls with two windows each
    x0, x1 = (-hx, -hx + T) if sx < 0 else (hx - T, hx)
    ys = [-hy, -2.6, -1.2, 1.2, 2.6, hy]
    for k in range(len(ys) - 1):
        a, b = ys[k], ys[k + 1]
        if k in (1, 3):                                                                       # window bays
            box(bm, uv, x0, a, 0.0, x1, b, 1.1, mi=0, tile=2.0)
            box(bm, uv, x0, a, 2.6, x1, b, H, mi=0, tile=2.0)
            box(bm, uv, x0 + 0.12, a, 1.1, x1 - 0.12, b, 2.6, mi=4)
        else:
            box(bm, uv, x0, a, 0.0, x1, b, H, mi=0, tile=2.0)
# front wall with a 1.0 x 2.3 m doorway (steel door with keypad, spawned by the door system)
box(bm, uv, -hx, -hy, 0.0, -0.5, -hy + T, H, mi=0, tile=2.0)
box(bm, uv, 0.5, -hy, 0.0, hx, -hy + T, H, mi=0, tile=2.0)
box(bm, uv, -0.5, -hy, 2.3, 0.5, -hy + T, H, mi=0, tile=2.0)
# entrance lobby (3 m high walls) with a door into the equipment hall
LZ = 3.0
box(bm, uv, -2.06, -hy + T, 0.15, -1.94, -2.5, LZ, mi=1, tile=2.0)
box(bm, uv, 1.94, -hy + T, 0.15, 2.06, -2.5, LZ, mi=1, tile=2.0)
box(bm, uv, -2.06, -2.56, 0.15, -0.5, -2.44, LZ, mi=1, tile=2.0)
box(bm, uv, 0.5, -2.56, 0.15, 2.06, -2.44, LZ, mi=1, tile=2.0)
box(bm, uv, -0.5, -2.56, 2.3, 0.5, -2.44, LZ, mi=1, tile=2.0)
box(bm, uv, -2.06, -hy + T, LZ, 2.06, -2.44, LZ + 0.08, mi=1, tile=2.0)          # lobby ceiling
box(bm, uv, -0.3, -3.9, LZ - 0.03, 0.3, -3.3, LZ, mi=5)
# power room partition (x = 4) with a door
box(bm, uv, 3.94, -hy + T, 0.15, 4.06, -1.0, H, mi=1, tile=2.0)
box(bm, uv, 3.94, 0.0, 0.15, 4.06, hy - T, H, mi=1, tile=2.0)
box(bm, uv, 3.94, -1.0, 2.3, 4.06, 0.0, H, mi=1, tile=2.0)
# painted interior skin (slightly inside the walls) so the inside isn't bare brick
box(bm, uv, -hx + T, hy - T - 0.01, 0.15, hx - T, hy - T, H - 0.05, mi=1, tile=2.0)
box(bm, uv, -hx + T, -hy + T, H - 0.06, hx - T, hy - T, H - 0.05, mi=1, tile=2.0)             # ceiling
# ceiling light panels (emissive), 2 rows x 4
for (x, y) in ((-5.5, -2.0), (-2.0, -1.0), (2.0, -1.0), (6.0, -2.0), (-5.5, 2.0), (-2.0, 2.0), (2.0, 2.0), (6.0, 2.0)):
    box(bm, uv, x - 0.6, y - 0.3, H - 0.08, x + 0.6, y + 0.3, H - 0.06, mi=5)
# sign over the door + canopy
box(bm, uv, -2.4, -hy - 0.05, 3.2, 2.4, -hy, 3.8, mi=6, front=6)
box(bm, uv, -1.2, -hy - 1.0, 2.55, 1.2, -hy, 2.65, mi=3)
add(finish('opslabs_exchange_building', bm, [mat('opslabs_ex_brick'), mat('opslabs_ex_wall'), mat('opslabs_ex_floor'), mat('opslabs_ex_roof'),
                                              mat('opslabs_ex_glass'), mat('opslabs_ex_light', 'emissive.sps'), mat('opslabs_ex_sign')]), 400.0, 'CONCRETE')

# --- racks (600 x 1000 x 2200)
for name, tex in (('opslabs_core_router', 'opslabs_ex_router_front'), ('opslabs_rectifier', 'opslabs_ex_rectifier_front')):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -0.30, -0.50, 0.0, 0.30, 0.50, 2.2, mi=0, front=1)
    for x in (-0.30, 0.27):
        box(bm, uv, x, -0.51, 0.0, x + 0.03, -0.49, 2.2, mi=2)
    add(finish(name, bm, [mat('opslabs_ex_rack'), mat(tex), mat('opslabs_ex_metal')]), 60.0, 'METAL_SOLID_MEDIUM')

# --- battery bank: two-tier steel stand, 12 blocks per tier
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
for z in (0.0, 0.75):
    box(bm, uv, -1.2, -0.35, z, 1.2, 0.35, z + 0.05, mi=1)
    for k in range(6):
        for j in range(2):
            x = -1.1 + k * 0.37
            y = -0.3 + j * 0.32
            box(bm, uv, x, y, z + 0.05, x + 0.32, y + 0.28, z + 0.55, mi=0, front=0)
for x in (-1.2, 1.15):
    for y in (-0.35, 0.3):
        box(bm, uv, x, y, 0.0, x + 0.05, y + 0.05, 1.35, mi=1)
add(finish('opslabs_battery_bank', bm, [mat('opslabs_ex_battery'), mat('opslabs_ex_metal')]), 60.0, 'METAL_SOLID_MEDIUM')

# --- standby diesel generator: containerised set 4 x 1.6 x 2.2 m with exhaust stack
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -2.0, -0.8, 0.0, 2.0, 0.8, 0.15, mi=1)
box(bm, uv, -1.95, -0.75, 0.15, 1.95, 0.75, 2.2, mi=0, front=0)
cyl(bm, uv, (1.5, 0.3, 2.2), (1.5, 0.3, 3.0), 0.09, sides=10, mi=1)
add(finish('opslabs_generator', bm, [mat('opslabs_ex_generator'), mat('opslabs_ex_metal')]), 150.0, 'METAL_SOLID_MEDIUM')

# --- HVAC: indoor CRAC unit (1.0 x 0.9 x 2.0) and outdoor condenser (1.4 x 0.8 x 1.2, fan on top)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.5, -0.45, 0.0, 0.5, 0.45, 2.0, mi=0, front=0)
add(finish('opslabs_crac', bm, [mat('opslabs_ex_crac')]), 60.0, 'METAL_SOLID_MEDIUM')
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.7, -0.4, 0.0, 0.7, 0.4, 1.2, mi=0)
box(bm, uv, -0.35, -0.35, 1.2, 0.35, 0.35, 1.22, mi=1)
add(finish('opslabs_condenser', bm, [mat('opslabs_ex_metal'), mat('opslabs_ex_fan')]), 100.0, 'METAL_SOLID_MEDIUM')

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
ytyp.name = 'opslabs_exchange_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_exchange.blend'))
