"""TP-Link style network props (generic look, no logos):
  Omada ER605 + ER7206 routers, Omada ceiling AP (ceiling + desk), Omada 8-port PoE switch,
  OC200 controller, Deco mesh unit, Archer router with antennas, plug-in range extender.
blender -b --python build_tplink.py -- <out_dir>
Fronts face -Y. Origin: bottom centre (ceiling AP: top centre, wall plug: back face).
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


def rj45(c, x, y, w, h, lit=True, led=(60, 220, 90)):
    c.rrect(x, y, x + w, y + h, 2, (22, 22, 24))
    c.rect(x + w * 0.18, y + h * 0.18, x + w * 0.82, y + h * 0.78, (8, 8, 9))
    for i in range(6):
        px = x + w * 0.24 + i * (w * 0.52 / 5)
        c.rect(px, y + h * 0.22, px + max(1, w * 0.05), y + h * 0.4, (190, 150, 60))
    c.rect(x + w * 0.38, y + h * 0.78, x + w * 0.62, y + h * 0.92, (8, 8, 9))
    if lit:
        c.rect(x + 1, y + 1, x + w * 0.2, y + h * 0.14, led)


def sfp(c, x, y, w, h):
    c.rrect(x, y, x + w, y + h, 2, (70, 72, 76))
    c.rect(x + 3, y + 3, x + w - 3, y + h - 3, (14, 14, 16))


def leds(c, x, y, n, gap, r, cols):
    for i in range(n):
        c.circle(x + i * gap, y, r, cols[i % len(cols)])


GREEN, AMBER, OFF, BLUE = (60, 220, 90), (255, 170, 40), (60, 62, 66), (60, 160, 255)
TEAL = (0, 190, 170)   # Omada-style accent stripe

# ---------------------------------------------------------------- textures
# dark metal chassis with a fine vent grid
c = Canvas(128, 128, (34, 36, 40))
for y in range(6, 128, 10):
    for x in range(6, 128, 10):
        c.rrect(x, y, x + 6, y + 2, 1, (18, 19, 22))
c.noise(3); save(c, 'opslabs_tp_metal')
c = Canvas(64, 64, (34, 36, 40)); c.noise(3); save(c, 'opslabs_tp_metal_plain')
c = Canvas(64, 64, (238, 239, 237)); c.noise(2); save(c, 'opslabs_tp_white')
c = Canvas(64, 64, (20, 20, 22)); c.noise(3); save(c, 'opslabs_tp_black')

# ER605 front 512x80 (158 x 25 mm): LEDs left, 5 ports, teal stripe
c = Canvas(512, 80, (30, 32, 36)); c.rect(0, 74, 512, 80, TEAL)
leds(c, 36, 30, 2, 22, 4, (GREEN, GREEN))
for i in range(5):
    rj45(c, 120 + i * 72, 14, 62, 50, lit=i != 3, led=AMBER if i == 0 else GREEN)
c.noise(2); save(c, 'opslabs_tp_er605_front')

# ER7206 front 1024x152 (294 x 44 mm): LEDs, 1 SFP + 5 ports, teal stripe
c = Canvas(1024, 152, (30, 32, 36)); c.rect(0, 144, 1024, 152, TEAL)
leds(c, 60, 50, 3, 30, 5, (GREEN, GREEN, BLUE))
sfp(c, 220, 40, 90, 50)
for i in range(5):
    rj45(c, 360 + i * 110, 30, 92, 74, lit=i in (0, 1, 2), led=AMBER if i == 0 else GREEN)
c.noise(2); save(c, 'opslabs_tp_er7206_front')

# switch front 512x64 (209 x 26 mm): 8 PoE ports + 2 SFP + LEDs
c = Canvas(512, 64, (30, 32, 36)); c.rect(0, 58, 512, 64, TEAL)
leds(c, 22, 20, 2, 16, 3, (GREEN, AMBER))
for i in range(8):
    rj45(c, 60 + i * 46, 10, 40, 38, lit=i % 3 != 2, led=AMBER if i < 4 else GREEN)
for i in range(2):
    sfp(c, 440 + i * 34, 14, 28, 26)
c.noise(2); save(c, 'opslabs_tp_switch_front')

# OC200 front 128x48: 2 ports + LEDs
c = Canvas(128, 48, (30, 32, 36)); c.rect(0, 44, 128, 48, TEAL)
leds(c, 14, 22, 2, 12, 3, (GREEN, BLUE))
for i in range(2):
    rj45(c, 46 + i * 38, 8, 32, 30, led=GREEN)
c.noise(2); save(c, 'opslabs_tp_oc200_front')

# Omada AP face: white with soft LED dot in the middle
c = Canvas(128, 128, (240, 241, 239))
c.circle(64, 64, 60, (232, 233, 231))
c.circle(64, 64, 7, (70, 210, 120)); c.circle(64, 64, 4, (180, 255, 200))
c.noise(2); save(c, 'opslabs_tp_eap_face')

# Deco top: white with an LED near the edge
c = Canvas(128, 128, (243, 243, 241))
c.circle(64, 64, 52, (236, 236, 234)); c.circle(64, 18, 4, (80, 200, 255))
c.noise(2); save(c, 'opslabs_tp_deco_top')

# Archer front 512x64: LED row, glossy black
c = Canvas(512, 64, (16, 16, 18)); c.vgrad(0, 0, 512, 64, (34, 34, 38), (12, 12, 14))
leds(c, 120, 32, 8, 36, 3, (BLUE,))
c.noise(2); save(c, 'opslabs_tp_archer_front')
# Archer back 512x64: WAN + 4 LAN + power
c = Canvas(512, 64, (18, 18, 20))
rj45(c, 60, 12, 44, 38, led=AMBER)
for i in range(4):
    rj45(c, 140 + i * 54, 12, 44, 38, lit=i != 2)
c.circle(440, 32, 10, (40, 40, 44)); c.circle(440, 32, 4, (10, 10, 12))
c.noise(2); save(c, 'opslabs_tp_archer_back')

# range extender front 128x128: white with LED column
c = Canvas(128, 128, (240, 241, 239))
leds(c, 64, 30, 1, 0, 4, (BLUE,)); leds(c, 64, 50, 1, 0, 4, (GREEN,)); leds(c, 64, 70, 1, 0, 4, (GREEN,))
c.rrect(30, 94, 98, 104, 4, (225, 226, 224))
c.noise(2); save(c, 'opslabs_tp_re_front')

# ---------------------------------------------------------------- materials
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


def quad(bm, uv, vs, mi, uvs=((0, 0), (1, 0), (1, 1), (0, 1))):
    f = bm.faces.new([bm.verts.new(v) for v in vs])
    f.material_index = mi
    for loop, u in zip(f.loops, uvs):
        loop[uv].uv = u
    return f


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, back=None, top=None):
    """front = -Y face material (full 0..1 UV), others tile mi"""
    F = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    for k, vs in F.items():
        m = {'front': front, 'back': back, 'top': top}.get(k)
        quad(bm, uv, vs, mi if m is None else m)


def rounded(bm, uv, W, D, z0, z1, R, mi=0, top_mi=None, bottom_mi=None, seg=8):
    """rounded-rectangle prism (R = W/2 = D/2 gives a cylinder). top/bottom get planar UVs"""
    pts = []
    for cx, cy, a0 in ((W / 2 - R, -D / 2 + R, -90), (W / 2 - R, D / 2 - R, 0), (-W / 2 + R, D / 2 - R, 90), (-W / 2 + R, -D / 2 + R, 180)):
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + R * math.cos(a), cy + R * math.sin(a)))
    clean = []
    for p in pts:
        if not clean or math.dist(p, clean[-1]) > 1e-6:
            clean.append(p)
    if math.dist(clean[0], clean[-1]) < 1e-6:
        clean.pop()
    n = len(clean)
    bot = [bm.verts.new((x, y, z0)) for x, y in clean]
    top = [bm.verts.new((x, y, z1)) for x, y in clean]
    for i in range(n):
        j = (i + 1) % n
        f = bm.faces.new((bot[i], bot[j], top[j], top[i]))
        f.material_index = mi
        f.smooth = True
        for loop, u in zip(f.loops, ((i / n, 0), (j / n, 0), (j / n, 1), (i / n, 1))):
            loop[uv].uv = u
    for ring, m, rev in ((top, top_mi, False), (bot, bottom_mi, True)):
        f = bm.faces.new(list(reversed(ring)) if rev else ring)
        f.material_index = mi if m is None else m
        for loop in f.loops:
            loop[uv].uv = (loop.vert.co.x / W + 0.5, loop.vert.co.y / D + 0.5)
    return top, bot


models = []   # (obj, lod, collision)


def feet(bm, uv, W, D, h=0.003, mi=0):
    for sx in (-1, 1):
        for sy in (-1, 1):
            x, y = sx * (W / 2 - 0.015), sy * (D / 2 - 0.015)
            box(bm, uv, x - 0.006, y - 0.006, 0.0, x + 0.006, y + 0.006, h, mi)


# ---- Omada ER605: 158 x 101 x 25 mm black metal desktop router
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H = 0.158, 0.101, 0.025
box(bm, uv, -W / 2, -D / 2, 0.003, W / 2, D / 2, 0.003 + H, mi=0, front=1, top=0)
feet(bm, uv, W, D, mi=2)
models.append((finish('opslabs_omada_er605', bm, [mat('opslabs_tp_metal'), mat('opslabs_tp_er605_front'), mat('opslabs_tp_black')]), 50.0, 'METAL_SOLID_SMALL'))

# ---- Omada ER7206: 294 x 180 x 44 mm, with rack ears
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H = 0.294, 0.180, 0.044
box(bm, uv, -W / 2, -D / 2, 0.003, W / 2, D / 2, 0.003 + H, mi=0, front=1)
for side in (-1, 1):
    x0 = -W / 2 - 0.02 if side < 0 else W / 2
    box(bm, uv, x0, -D / 2, 0.003, x0 + 0.02, -D / 2 + 0.002, 0.003 + H, mi=2)
feet(bm, uv, W, D, mi=3)
models.append((finish('opslabs_omada_er7206', bm, [mat('opslabs_tp_metal'), mat('opslabs_tp_er7206_front'), mat('opslabs_tp_metal_plain'), mat('opslabs_tp_black')]), 60.0, 'METAL_SOLID_SMALL'))

# ---- Omada 8-port PoE switch: 209 x 126 x 26 mm
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H = 0.209, 0.126, 0.026
box(bm, uv, -W / 2, -D / 2, 0.003, W / 2, D / 2, 0.003 + H, mi=0, front=1)
feet(bm, uv, W, D, mi=2)
models.append((finish('opslabs_omada_switch', bm, [mat('opslabs_tp_metal'), mat('opslabs_tp_switch_front'), mat('opslabs_tp_black')]), 50.0, 'METAL_SOLID_SMALL'))

# ---- OC200 controller: 95 x 60 x 24 mm
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H = 0.095, 0.060, 0.024
box(bm, uv, -W / 2, -D / 2, 0.002, W / 2, D / 2, 0.002 + H, mi=0, front=1)
feet(bm, uv, W, D, h=0.002, mi=2)
models.append((finish('opslabs_omada_oc200', bm, [mat('opslabs_tp_metal_plain'), mat('opslabs_tp_oc200_front'), mat('opslabs_tp_black')]), 40.0, 'PLASTIC'))

# ---- Omada ceiling AP: Ø 243 x 64 mm white disc with a domed face
def eap(name, ceiling):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    Rr = 0.1215
    rounded(bm, uv, 2 * Rr, 2 * Rr, 0.0, 0.040, Rr, mi=0, top_mi=0, bottom_mi=1, seg=10)
    # bevelled edge ring + slim mounting plate on the back
    rounded(bm, uv, 2 * Rr - 0.012, 2 * Rr - 0.012, -0.006, 0.0, Rr - 0.006, mi=0, top_mi=0, bottom_mi=1, seg=10)
    rounded(bm, uv, 0.12, 0.12, 0.040, 0.048, 0.06, mi=0, top_mi=0, seg=8)
    # built face-down (face = mi 1 at the bottom, mounting plate on top)
    for v in bm.verts:
        v.co.z = v.co.z - 0.048 if ceiling else 0.048 - v.co.z   # ceiling: hang below the origin · desk: face up
    if not ceiling:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)              # mirrored, so flip the winding back
    models.append((finish(name, bm, [mat('opslabs_tp_white'), mat('opslabs_tp_eap_face')]), 50.0, 'PLASTIC'))


eap('opslabs_omada_eap_ceiling', True)
eap('opslabs_omada_eap', False)

# ---- Deco mesh unit: Ø 120 x 38 mm white puck
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
rounded(bm, uv, 0.120, 0.120, 0.004, 0.038, 0.060, mi=0, top_mi=1, seg=10)
rounded(bm, uv, 0.100, 0.100, 0.0, 0.004, 0.050, mi=2, seg=8)
models.append((finish('opslabs_tplink_deco', bm, [mat('opslabs_tp_white'), mat('opslabs_tp_deco_top'), mat('opslabs_tp_black')]), 40.0, 'PLASTIC'))

# ---- Archer router: 260 x 135 x 38 mm black with 4 folding antennas
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
W, D, H = 0.260, 0.135, 0.038
rounded(bm, uv, W, D, 0.004, 0.004 + H, 0.02, mi=0, seg=6)
quad(bm, uv, [(-W / 2 + 0.02, -D / 2 - 0.0004, 0.006), (W / 2 - 0.02, -D / 2 - 0.0004, 0.006), (W / 2 - 0.02, -D / 2 - 0.0004, 0.004 + H - 0.002), (-W / 2 + 0.02, -D / 2 - 0.0004, 0.004 + H - 0.002)], 1)
quad(bm, uv, [(W / 2 - 0.02, D / 2 + 0.0004, 0.006), (-W / 2 + 0.02, D / 2 + 0.0004, 0.006), (-W / 2 + 0.02, D / 2 + 0.0004, 0.004 + H - 0.002), (W / 2 - 0.02, D / 2 + 0.0004, 0.004 + H - 0.002)], 2)
feet(bm, uv, W, D, h=0.004, mi=0)
for i, x in enumerate((-0.10, -0.035, 0.035, 0.10)):
    start = len(bm.verts)
    box(bm, uv, -0.007, -0.003, 0.0, 0.007, 0.003, 0.16, mi=0)
    bm.verts.ensure_lookup_table()
    tilt = math.radians(-12 if x < 0 else 12)
    for v in bm.verts[start:]:
        vx, vy, vz = v.co
        vx, vz = vx * math.cos(tilt) + vz * math.sin(tilt), -vx * math.sin(tilt) + vz * math.cos(tilt)
        v.co = (x + vx, D / 2 - 0.008 + vy, 0.004 + H - 0.01 + vz)
models.append((finish('opslabs_tplink_archer', bm, [mat('opslabs_tp_black'), mat('opslabs_tp_archer_front'), mat('opslabs_tp_archer_back')]), 50.0, 'PLASTIC'))

# ---- range extender (plugs into a wall socket): 80 x 52 x 120 mm, origin on the back face
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
rounded(bm, uv, 0.080, 0.052, 0.0, 0.120, 0.012, mi=0, seg=5)
for v in bm.verts:
    x, y, z = v.co
    v.co = (x, y - 0.026, z)     # back face at y = 0, front towards -Y
quad(bm, uv, [(-0.028, -0.0524, 0.01), (0.028, -0.0524, 0.01), (0.028, -0.0524, 0.11), (-0.028, -0.0524, 0.11)], 1)
models.append((finish('opslabs_tplink_extender', bm, [mat('opslabs_tp_white'), mat('opslabs_tp_re_front')]), 30.0, 'PLASTIC'))

# ---------------------------------------------------------------- export
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
ytyp.name = 'opslabs_tplink_props'
bpy.ops.object.select_all(action='DESELECT')
for d, _ in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0][0]
bpy.ops.sollumz.createarchetypefromselected()
lods = {d.name: lod for d, lod in drawables}
for a in ytyp.archetypes:
    a.lod_dist = lods.get(a.name, 50.0)
print('ARCHETYPES', len(ytyp.archetypes))
res = bpy.ops.sollumz.export_assets(directory=OUT, direct_export=True, use_custom_settings=True,
                                    target_formats={'CWXML'}, target_versions={'GEN8'}, limit_to_selected=False, export_ytyps=True)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_tplink.blend'))
