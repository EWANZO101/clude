"""Aluminium extension ladder: base section + fly section (slides up behind it).
blender -b --python build_ladder.py -- <out_dir>
Both models stand along +Z with the origin at the base section's foot (bottom centre), the
climbing side facing -Y. The fly sits behind the base (+Y); in game it is moved up the ladder
axis by the extension, so at 0 m it overlaps the base fully.
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
exec(open(os.path.join(HERE, 'canvas_lib.py')).read())


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


c = Canvas(64, 256, (188, 192, 196)); c.brushed(8); c.noise(2); save(c, 'opslabs_ladder_alu')
c = Canvas(32, 32, (22, 22, 24)); c.noise(3); save(c, 'opslabs_ladder_rubber')
# rail label: yellow safety sticker with black chevrons
c = Canvas(64, 256, (188, 192, 196)); c.brushed(8)
c.rect(8, 60, 56, 196, (235, 190, 30))
for y in range(70, 186, 22):
    c.rect(14, y, 50, y + 8, (25, 25, 25))
c.noise(2); save(c, 'opslabs_ladder_label')

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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, vrep=1.0):
    F = [
        [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    ]
    for vs in F:
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, vrep), (0, vrep))):
            loop[uv].uv = u


def rung(bm, uv, x0, x1, y, z, r, mi=0, sides=8):
    rings = []
    for x in (x0, x1):
        rings.append([bm.verts.new((x, y + r * math.cos(2 * math.pi * i / sides), z + r * math.sin(2 * math.pi * i / sides))) for i in range(sides)])
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][j], rings[0][i], rings[1][i], rings[1][j]))
        f.material_index = mi
        f.smooth = True
        for loop, u in zip(f.loops, ((j / sides, 0), (i / sides, 0), (i / sides, 1), (j / sides, 1))):
            loop[uv].uv = u


def finish(name, bm, mats):
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


models = []
RUNG = 0.28


def build(prefix, L, half_w, rail_w, rail_d):
    """base + fly. L = section length, half_w = half the base width, rail = width x depth"""
    rw, rd = rail_w / 2, rail_d / 2
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    for s in (-1, 1):
        x = s * half_w
        box(bm, uv, x - rw, -rd, 0.05, x + rw, rd, L, mi=0, vrep=L / 1.5)
        box(bm, uv, x - rw - 0.0003, -rd - 0.0003, 0.9, x + rw + 0.0003, -rd + 0.0003, 1.5, mi=2)   # safety label
        box(bm, uv, x - rw - 0.008, -rd - 0.012, 0.0, x + rw + 0.008, rd + 0.012, 0.06, mi=1)        # rubber foot
        box(bm, uv, x - rw - 0.0015, -rd - 0.0015, L - 0.03, x + rw + 0.0015, rd + 0.0015, L + 0.01, mi=1)
    k = 1
    while k * RUNG < L - 0.1:
        rung(bm, uv, -half_w + rw, half_w - rw, 0.0, k * RUNG, 0.016)
        k += 1
    models.append(finish(prefix + '_base', bm, [mat('opslabs_ladder_alu'), mat('opslabs_ladder_rubber'), mat('opslabs_ladder_label')]))

    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    z0, fw, yc = 0.30, half_w - 0.03, rail_d + 0.005
    for s in (-1, 1):
        x = s * fw
        box(bm, uv, x - rw, yc - rd, z0, x + rw, yc + rd, z0 + L, mi=0, vrep=L / 1.5)
        box(bm, uv, x - rw - 0.0015, yc - rd - 0.0015, z0 + L - 0.03, x + rw + 0.0015, yc + rd + 0.0015, z0 + L + 0.01, mi=1)
        bx0, bx1 = sorted((x, s * half_w + s * (rw + 0.004)))
        box(bm, uv, bx0, -rd - 0.008, z0 + 0.05, bx1, yc - rd + 0.002, z0 + 0.11, mi=0)               # guide brackets
    k = 1
    while k * RUNG < L - 0.1:
        rung(bm, uv, -fw + rw, fw - rw, yc, z0 + k * RUNG, 0.016)
        k += 1
    models.append(finish(prefix + '_fly', bm, [mat('opslabs_ladder_alu'), mat('opslabs_ladder_rubber')]))


build('opslabs_ladder', 3.6, 0.225, 0.025, 0.065)       # 3.6 m sections -> 6.9 m
build('opslabs_ladder13', 6.8, 0.26, 0.030, 0.085)      # 6.8 m sections -> 13 m

scene = bpy.context.scene
scene.create_seperate_drawables = True
scene.auto_create_embedded_col = False
drawables = []
for obj in models:
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.sollumz.converttodrawable()
    drawables.append(obj.parent)
bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_ladder_props'
bpy.ops.object.select_all(action='DESELECT')
for d in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0]
bpy.ops.sollumz.createarchetypefromselected()
for a in ytyp.archetypes:
    a.lod_dist = 80.0
print('ARCHETYPES', len(ytyp.archetypes))
res = bpy.ops.sollumz.export_assets(directory=OUT, direct_export=True, use_custom_settings=True,
                                    target_formats={'CWXML'}, target_versions={'GEN8'}, limit_to_selected=False, export_ytyps=True)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_ladder.blend'))
