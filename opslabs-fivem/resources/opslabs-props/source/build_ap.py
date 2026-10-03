"""Builds a UniFi-style ceiling access point (U6-Pro proportions) and exports it
with Sollumz as CodeWalker XML (.ydr.xml + .ytyp.xml).

Run:  blender -b --python build_ap.py -- <out_dir>
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
PLASTIC = next(i for i, m in enumerate(sz_col.collisionmats) if m.name == 'PLASTIC') if hasattr(sz_col, 'collisionmats') else 0


# ---------------------------------------------------------------------------
# DDS textures (uncompressed A8R8G8B8 + full mip chain)
# ---------------------------------------------------------------------------

def write_dds(path, size, pixel):
    w = h = size
    mips = int(math.log2(size)) + 1
    data = bytearray()
    for m in range(mips):
        mw = max(1, w >> m)
        for y in range(mw):
            for x in range(mw):
                r, g, b, a = pixel(x / mw, y / mw)
                data += bytes((b, g, r, a))
    DDSD = 0x1 | 0x2 | 0x4 | 0x1000 | 0x8 | 0x20000  # caps|height|width|pixelformat|pitch|mipmapcount
    header = struct.pack('<4sIIIIIII44x', b'DDS ', 124, DDSD, h, w, w * 4, 0, mips)
    pf = struct.pack('<II4sIIIII', 32, 0x41, b'\0\0\0\0', 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    caps = struct.pack('<IIII4x', 0x1000 | 0x8 | 0x400000, 0, 0, 0)
    with open(path, 'wb') as f:
        f.write(header + pf + caps + data)


def body_px(u, v):
    # warm matte white with a very soft radial falloff (moulded plastic)
    d = math.hypot(u - 0.5, v - 0.5)
    k = int(246 - d * 10)
    return (k, k, k - 2, 255)


def led_px(u, v):
    return (70, 170, 255, 255)   # UniFi "ready" blue


write_dds(os.path.join(TEX, 'opslabs_ap_body.dds'), 64, body_px)
write_dds(os.path.join(TEX, 'opslabs_ap_led.dds'), 16, led_px)


# ---------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)

SEG = 64
# (radius, height) — U6-Pro: Ø197 mm, ~38 mm tall, soft rounded edge, slight dome
BODY_PROFILE = [
    (0.0, 0.0), (0.080, 0.0), (0.090, 0.0015), (0.0960, 0.0055), (0.0985, 0.0115),
    (0.0985, 0.0190), (0.0965, 0.0265), (0.0910, 0.0320), (0.0790, 0.0352),
    (0.0600, 0.0370), (0.0370, 0.0378), (0.0, 0.0381),
]
LED_RING = (0.0300, 0.0345, 0.0379, 0.0389)  # inner r, outer r, z bottom, z top


def lathe(bm, profile, seg):
    """revolve a (r, z) profile around Z"""
    rings = []
    for i in range(seg):
        a = 2 * math.pi * i / seg
        ca, sa = math.cos(a), math.sin(a)
        ring = []
        for r, z in profile:
            ring.append(bm.verts.new((r * ca, r * sa, z)))
        rings.append(ring)
    for i in range(seg):
        r0, r1 = rings[i], rings[(i + 1) % seg]
        for j in range(len(profile) - 1):
            vs = [r0[j], r1[j], r1[j + 1], r0[j + 1]]
            if profile[j][0] == 0.0:      # bottom centre fan
                vs = [r0[j], r1[j + 1], r0[j + 1]]
            elif profile[j + 1][0] == 0.0:  # top centre fan
                vs = [r0[j], r1[j], r0[j + 1]]
            try:
                bm.faces.new(vs)
            except ValueError:
                pass
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-6)


def make_part(name, profile, mat):
    bm = bmesh.new()
    lathe(bm, profile, SEG)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for p in me.polygons:
        p.use_smooth = True
    uv = me.uv_layers.new(name='UVMap 0')
    for l in uv.data:
        l.uv = (0.5, 0.5)
    col = me.color_attributes.new('Color 1', 'BYTE_COLOR', 'CORNER')
    for d in col.data:
        d.color = (1.0, 1.0, 1.0, 1.0)
    me.materials.append(mat)
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def material(shader, dds, extra=None):
    mat = sz_mats.create_shader(shader)
    img = bpy.data.images.load(os.path.join(TEX, dds), check_existing=True)
    img.name = os.path.splitext(dds)[0]
    for node in mat.node_tree.nodes:
        if isinstance(node, bpy.types.ShaderNodeTexImage) and node.name == 'DiffuseSampler':
            node.image = img
            node.texture_properties.embedded = True
    if extra:
        extra(mat)
    return mat


def boost_emissive(mat):
    n = mat.node_tree.nodes.get('emissiveMultiplier')
    if n is not None:
        try:
            n.set('X', 4.0)
        except Exception:
            for attr in ('X', 'x'):
                if hasattr(n, attr):
                    setattr(n, attr, 4.0)


body_mat = material('default.sps', 'opslabs_ap_body.dds')
led_mat = material('emissive.sps', 'opslabs_ap_led.dds', boost_emissive)

ri, ro, zb, zt = LED_RING
LED_PROFILE = [(ri, zb), (ro, zb), (ro, zt), (ri, zt), (ri, zb)]


def build(name, ceiling):
    body = make_part(name + '_body', BODY_PROFILE, body_mat)
    led = make_part(name + '_led', LED_PROFILE, led_mat)
    bpy.ops.object.select_all(action='DESELECT')
    body.select_set(True)
    led.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    obj.data.name = name
    if ceiling:
        # mounted dome-down, origin on the ceiling surface
        obj.rotation_euler = (math.pi, 0.0, 0.0)
        bpy.ops.object.transform_apply(location=False, rotation=True, scale=False)
    return obj


desk = build('opslabs_unifi_ap', ceiling=False)
ceil = build('opslabs_unifi_ap_ceiling', ceiling=True)

# ---------------------------------------------------------------------------
# Sollumz: drawables with embedded collision + a ytyp with both archetypes
# ---------------------------------------------------------------------------

scene = bpy.context.scene
scene.auto_create_embedded_col = True
scene.create_seperate_drawables = True
drawables = []
for obj in (desk, ceil):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.sollumz.converttodrawable()
    d = bpy.data.objects[obj.name.replace('.model', '')] if obj.name.endswith('.model') else obj.parent
    drawables.append(d)
print('DRAWABLES', [d.name for d in drawables])
# embedded collision: plastic, not the visual shaders
col_mat = sz_col.create_collision_material_from_index(PLASTIC)
for d in drawables:
    for child in d.children_recursive:
        if child.type == 'MESH' and 'poly_mesh' in child.name:
            child.data.materials.clear()
            child.data.materials.append(col_mat)
            print('collision material ->', child.name, col_mat.name)

bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_wifi_props'
bpy.ops.object.select_all(action='DESELECT')
for d in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0]
bpy.ops.sollumz.createarchetypefromselected()
for a in ytyp.archetypes:
    a.lod_dist = 80.0
print('ARCHETYPES', [(a.name, a.asset_type, a.texture_dictionary) for a in ytyp.archetypes])

for d in drawables:
    d.select_set(True)
res = bpy.ops.sollumz.export_assets(
    directory=OUT, direct_export=True, use_custom_settings=True,
    target_formats={'CWXML'}, target_versions={'GEN8'},
    limit_to_selected=False, export_ytyps=True,
)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_unifi_ap.blend'))
