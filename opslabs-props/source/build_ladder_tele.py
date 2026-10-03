"""Telescopic aluminium ladder: 10 identical-pitch sections the game stacks along the ladder axis
(nested when closed, end-to-end when open). Same conventions as build_ladder.py: each section stands
along +Z, origin = bottom centre of the section, climbing side faces -Y, no collision.
  opslabs_ladder_tele_base  bottom section: stiles d 0.030 at x = +-0.225, z 0 .. 0.32, rubber feet z 0 .. 0.04,
                            flat-topped oval rung at z = 0.30, black collars z 0.26 .. 0.32
  opslabs_ladder_tele_sec   every other section (top too): stiles d 0.028, rung at z = 0.30, collar with a
                            release button on each stile z 0.26 .. 0.32
blender -b --python build_ladder_tele.py -- <out_dir>
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
exec(open(os.path.join(HERE, 'canvas_lib.py')).read())

SX, LEN, RZ = 0.225, 0.32, 0.30          # stile x, section length (pitch), rung z


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


c = Canvas(64, 256, (192, 196, 200)); c.brushed(9); c.noise(2); save(c, 'opslabs_tele_alu')
c = Canvas(32, 32, (24, 24, 26)); c.noise(3); save(c, 'opslabs_tele_black')
c = Canvas(32, 32, (14, 14, 14)); c.noise(2); save(c, 'opslabs_tele_rubber')
c = Canvas(32, 32, (96, 98, 102)); c.noise(3); save(c, 'opslabs_tele_button')

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


def prism(bm, uv, prof, x0, x1, mi=0, vrep=1.0, smooth=True):
    """extrude a closed (y, z) profile along X from x0 to x1"""
    n = len(prof)
    a = [bm.verts.new((x0, y, z)) for y, z in prof]
    b = [bm.verts.new((x1, y, z)) for y, z in prof]
    for i in range(n):
        j = (i + 1) % n
        f = bm.faces.new((a[i], b[i], b[j], a[j]))
        f.material_index = mi
        f.smooth = smooth
        for loop, u in zip(f.loops, ((i / n, 0), (i / n, vrep), ((i + 1) / n, vrep), ((i + 1) / n, 0))):
            loop[uv].uv = u
    for ring in (list(reversed(a)), b):
        f = bm.faces.new(ring)
        f.material_index = mi
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)


def zcyl(bm, uv, x, y, z0, z1, r, sides=14, mi=0, vrep=1.0):
    prof = [(r * math.cos(2 * math.pi * k / sides), r * math.sin(2 * math.pi * k / sides)) for k in range(sides)]
    n = sides
    a = [bm.verts.new((x + px, y + py, z0)) for px, py in prof]
    b = [bm.verts.new((x + px, y + py, z1)) for px, py in prof]
    for i in range(n):
        j = (i + 1) % n
        f = bm.faces.new((a[i], a[j], b[j], b[i]))
        f.material_index = mi
        f.smooth = True
        for loop, u in zip(f.loops, ((i / n, 0), ((i + 1) / n, 0), ((i + 1) / n, vrep), (i / n, vrep))):
            loop[uv].uv = u
    for ring in (list(reversed(a)), b):
        f = bm.faces.new(ring)
        f.material_index = mi
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)


def xcyl(bm, uv, x0, x1, y, z, r, sides=10, mi=0):
    prism(bm, uv, [(y + r * math.cos(2 * math.pi * k / sides), z + r * math.sin(2 * math.pi * k / sides)) for k in range(sides)], x0, x1, mi=mi)


# flat-topped oval rung: 0.028 deep (y) x 0.022 tall, top flattened 0.008 above the centre (tread)
RUNG = []
for k in range(16):
    t = 2 * math.pi * k / 16
    RUNG.append((0.014 * math.cos(t), RZ + min(0.008, 0.011 * math.sin(t))))


def section(name, stile_r, base):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    for sx in (-1, 1):
        zcyl(bm, uv, sx * SX, 0.0, 0.0, LEN, stile_r, mi=0, vrep=1.0)                        # stile
        zcyl(bm, uv, sx * SX, 0.0, 0.26, LEN, stile_r + 0.006, mi=1)                         # plastic collar
        if base:
            zcyl(bm, uv, sx * SX, 0.0, 0.0, 0.04, stile_r + 0.008, mi=2)                     # rubber foot
            zcyl(bm, uv, sx * SX, 0.0, -0.0, 0.004, stile_r + 0.010, mi=2)                   # foot sole lip
        else:
            o = sx * (SX + stile_r + 0.006)
            xcyl(bm, uv, o, o + sx * 0.007, 0.0, 0.275, 0.006, mi=3)                         # release button (outer side)
            xcyl(bm, uv, o - sx * 0.001, o + sx * 0.002, 0.0, 0.275, 0.009, mi=1)            # button bezel
    prism(bm, uv, RUNG, -SX, SX, mi=0)                                                       # rung (ends inside the stiles)
    for k in range(3):                                                                       # tread ridges on the flat top
        y = -0.008 + k * 0.008
        prism(bm, uv, [(y - 0.0015, RZ + 0.008), (y + 0.0015, RZ + 0.008), (y + 0.0015, RZ + 0.0095), (y - 0.0015, RZ + 0.0095)],
              -SX + stile_r, SX - stile_r, mi=0, smooth=False)
    return finish(name, bm, [mat('opslabs_tele_alu'), mat('opslabs_tele_black'), mat('opslabs_tele_rubber'), mat('opslabs_tele_button')])


models = [section('opslabs_ladder_tele_base', 0.015, True), section('opslabs_ladder_tele_sec', 0.014, False)]

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
ytyp.name = 'opslabs_ladder_tele_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_ladder_tele.blend'))
