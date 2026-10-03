"""OPS Network van roof spotlight: a remotely controlled searchlight on a roof cross-bar for the
base-game `speedo`. Five separate parts so the client can slide / raise / pan / tilt them, plus
the glowing lens. No collision (everything is attached to the vehicle).
blender -b --python build_vanspot.py -- <out_dir>
Origins (the client relies on these):
  opslabs_van_spot_rail     centre of the bar at roof level (z = 0); bar along X (1.50 m), top of the rail z = 0.10,
                            clamp feet at x = +-0.70 down to the roof.
  opslabs_van_spot_post     carriage bottom centre (sits on the rail top); the carriage slides along X,
                            outer tube (Ø 50) top at z = 0.25.
  opslabs_van_spot_mast     the TOP of the telescopic inner tube (Ø 40); the tube hangs down to z = -0.40.
  opslabs_van_spot_yoke     bottom centre of the pan turntable (pan axis = Z); arms at x = +-0.15,
                            tilt axis = X axis at z = 0.22 (head clears the turntable through a full tilt).
  opslabs_van_spot_head     the tilt pivot (tilt axis = X); beam along +Y, lens face at y = +0.11.
  opslabs_van_spot_head_on  the glowing lens only, same origin as the head, a hair in front of the glass.
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
sz_col = import_module(addon + '.ybn.collision_materials')
exec(open(os.path.join(HERE, 'canvas_lib.py')).read())


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))


# ---------------------------------------------------------------- textures
c = Canvas(64, 64, (26, 26, 28)); c.noise(4); save(c, 'opslabs_vs_black')               # black powder coat
c = Canvas(64, 64, (12, 12, 13)); c.noise(2); save(c, 'opslabs_vs_rubber')
c = Canvas(64, 256, (176, 180, 184)); c.brushed(10); save(c, 'opslabs_vs_alu')           # brushed aluminium
c = Canvas(64, 64, (60, 62, 66))                                                         # chrome: banded reflections
c.vgrad(0, 0, 64, 20, (235, 238, 242), (120, 124, 130)); c.vgrad(0, 20, 64, 40, (90, 92, 96), (250, 250, 252))
c.vgrad(0, 40, 64, 64, (210, 212, 216), (110, 112, 116)); save(c, 'opslabs_vs_chrome')


def lens(name, glow=False):
    """front of the lamp: faceted reflector seen through clear glass, LED emitter in the middle"""
    c = Canvas(128, 128, (0, 0, 0))
    for r in range(64, 0, -1):
        if glow:
            v = 255 - int(30 * (r / 64) ** 2)
            col = (v, int(v * 0.95), int(v * 0.86))                                       # ≈ 5000 K warm white
        else:
            band = (r // 6) % 2
            v = int(150 + 70 * (r / 64)) - band * 40
            col = (v, v, min(255, v + 6))
        c.circle(64, 64, r, col)
    c.circle(64, 64, 12, (255, 252, 240) if glow else (236, 226, 170))                   # emitter
    c.circle(64, 64, 6, (255, 255, 255) if glow else (250, 246, 220))
    if not glow:
        c.rect(30, 22, 56, 26, (245, 248, 252), 0.6)                                      # glass glint
    save(c, name)


lens('opslabs_vs_lens')
lens('opslabs_vs_glow', glow=True)

MATS = {}


def mat(name, shader='default.sps'):
    key = (name, shader)
    if key in MATS:
        return MATS[key]
    m = sz_mats.create_shader(shader)
    m.name = name
    img = bpy.data.images.load(os.path.join(TEX, name + '.dds'), check_existing=True)
    img.name = name
    for node in m.node_tree.nodes:
        if isinstance(node, bpy.types.ShaderNodeTexImage) and node.name == 'DiffuseSampler':
            node.image = img
            node.texture_properties.embedded = True
    MATS[key] = m
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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, back=None, bottom=None):
    F = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    over = {'front': front, 'back': back, 'bottom': bottom}
    for k, vs in F.items():
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = over[k] if over.get(k) is not None else mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


def cyl(bm, uv, p0, p1, r0, r1=None, sides=12, mi=0, vrep=1.0):
    r1 = r0 if r1 is None else r1
    a, b = mathutils.Vector(p0), mathutils.Vector(p1)
    d = (b - a).normalized()
    t = mathutils.Vector((1, 0, 0)) if abs(d.x) < 0.9 else mathutils.Vector((0, 1, 0))
    u = d.cross(t).normalized()
    w = d.cross(u).normalized()
    rings = [[bm.verts.new(c + (u * math.cos(2 * math.pi * i / sides) + w * math.sin(2 * math.pi * i / sides)) * r) for i in range(sides)] for c, r in ((a, r0), (b, r1))]
    for i in range(sides):
        j = (i + 1) % sides
        f = bm.faces.new((rings[0][i], rings[0][j], rings[1][j], rings[1][i]))
        f.material_index = mi
        f.smooth = True
        for loop, uvv in zip(f.loops, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, vrep), (i / sides, vrep))):
            loop[uv].uv = uvv
    for k, ring in enumerate(rings):
        if (r0 if k == 0 else r1) > 0.0005:
            f = bm.faces.new(ring if k else list(reversed(ring)))
            f.material_index = mi
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.5)


def orient(f, want):
    """flip face `f` so its normal points along `want`"""
    f.normal_update()
    if f.normal.dot(mathutils.Vector(want)) < 0:
        f.normal_flip()


def disc_y(bm, uv, y, r, mi=0, sides=24, back=False):
    """flat disc in the XZ plane at `y` facing +Y (or -Y when `back`), planar UV over the full texture"""
    vs = [bm.verts.new((r * math.cos(2 * math.pi * i / sides), y, r * math.sin(2 * math.pi * i / sides))) for i in range(sides)]
    f = bm.faces.new(vs)
    orient(f, (0, -1 if back else 1, 0))
    f.material_index = mi
    for loop in f.loops:
        co = loop.vert.co
        loop[uv].uv = (0.5 + co.x / (2 * r), 0.5 + co.z / (2 * r))


def ring_y(bm, uv, y0, y1, ri, ro, mi=0, sides=24):
    """annular ring along Y (y0 < y1): outer wall, inner wall and both faces"""
    def rv(r, y):
        return [bm.verts.new((r * math.cos(2 * math.pi * i / sides), y, r * math.sin(2 * math.pi * i / sides))) for i in range(sides)]
    oa, ob, ia, ib = rv(ro, y0), rv(ro, y1), rv(ri, y0), rv(ri, y1)
    for i in range(sides):
        j = (i + 1) % sides
        a = 2 * math.pi * (i + 0.5) / sides
        out = (math.cos(a), 0, math.sin(a))
        for vs, want in (((oa[i], oa[j], ob[j], ob[i]), out), ((ia[i], ia[j], ib[j], ib[i]), tuple(-v for v in out)),
                         ((ob[i], ob[j], ib[j], ib[i]), (0, 1, 0)), ((oa[i], oa[j], ia[j], ia[i]), (0, -1, 0))):
            f = bm.faces.new(vs)
            orient(f, want)
            f.material_index = mi
            f.smooth = want[1] == 0
            vmax = 1.0 if want[1] == 0 else 0.3          # flat faces: one soft band only
            uvs = dict(zip(vs, ((i / sides, 0), ((i + 1) / sides, 0), ((i + 1) / sides, vmax), (i / sides, vmax))))
            for loop in f.loops:                         # by vertex: orient() may have reordered the loops
                loop[uv].uv = uvs[loop.vert]


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


def bar_xz(bm, uv, p0, p1, ht, hy, mi=0):
    """rectangular bar between two points in the XZ plane: ht = half thickness (in XZ), hy = half width along Y"""
    a, b = mathutils.Vector(p0), mathutils.Vector(p1)
    d = (b - a).normalized()
    n = mathutils.Vector((-d.z, 0, d.x))
    pts = [(c, s1, s2) for c in (a, b) for s1 in (-1, 1) for s2 in (-1, 1)]
    vs = [bm.verts.new(c + n * (s1 * ht) + mathutils.Vector((0, s2 * hy, 0))) for c, s1, s2 in pts]
    # index: 0 a-- 1 a-+ 2 a+- 3 a++ 4 b-- 5 b-+ 6 b+- 7 b++
    for q in ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)):
        f = bm.faces.new([vs[i] for i in q])
        f.material_index = mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u
    return vs


BLK, RUB, ALU, CHR, LNS = 0, 1, 2, 3, 4
PARTS = lambda: [mat('opslabs_vs_black'), mat('opslabs_vs_rubber'), mat('opslabs_vs_alu'), mat('opslabs_vs_chrome'), mat('opslabs_vs_lens')]
LOD = 150.0

# --- roof rail: 1.50 m aluminium cross-bar along X, 40 x 40 profile with a T-slot on top (top at
#     z = 0.10), black end caps, two clamp feet at x = +-0.70 down to the roof (z = 0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.75, -0.02, 0.06, 0.75, 0.02, 0.092, mi=ALU)                          # profile body
for y0, y1 in ((-0.02, -0.004), (0.004, 0.02)):
    box(bm, uv, -0.75, y0, 0.092, 0.75, y1, 0.10, mi=ALU)                            # T-slot lips
box(bm, uv, -0.75, -0.004, 0.0918, 0.75, 0.004, 0.0924, mi=BLK)                      # slot (dark)
for s in (-1, 1):
    box(bm, uv, -0.75, s * 0.0195 - 0.0006, 0.073, 0.75, s * 0.0195 + 0.0006, 0.079, mi=BLK)   # side slots
    box(bm, uv, min(s * 0.75, s * 0.757), -0.0205, 0.0595, max(s * 0.75, s * 0.757), 0.0205, 0.1005, mi=BLK)  # end cap
    x = s * 0.70
    box(bm, uv, x - 0.035, -0.03, 0.045, x + 0.035, 0.03, 0.06, mi=BLK)              # clamp block
    box(bm, uv, x - 0.035, -0.03, 0.06, x + 0.035, -0.02, 0.085, mi=BLK)             # clamp jaws round the profile
    box(bm, uv, x - 0.035, 0.02, 0.06, x + 0.035, 0.03, 0.085, mi=BLK)
    box(bm, uv, x - 0.02, -0.02, 0.015, x + 0.02, 0.02, 0.045, mi=BLK)               # foot leg
    box(bm, uv, x - 0.045, -0.05, 0.0, x + 0.045, 0.05, 0.015, mi=RUB)               # rubber pad on the roof
    for sx in (-1, 1):
        cyl(bm, uv, (x + sx * 0.022, -0.03, 0.072), (x + sx * 0.022, -0.034, 0.072), 0.005, sides=6, mi=CHR)  # clamp bolts
add(finish('opslabs_van_spot_rail', bm, PARTS()), LOD)

# --- sliding post: carriage block 0.12 x 0.10 x 0.05 clamped on the rail (jaws hang down the rail
#     sides), clamp knob, fixed outer tube Ø 50 with a lock collar; tube top at z = 0.25
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.06, -0.05, 0.0, 0.06, 0.05, 0.05, mi=BLK)                             # carriage
for s in (-1, 1):
    box(bm, uv, -0.05, min(s * 0.021, s * 0.03), -0.03, 0.05, max(s * 0.021, s * 0.03), 0.0, mi=BLK)   # jaws
for x in (-0.045, 0.045):
    cyl(bm, uv, (x, -0.05, 0.035), (x, -0.053, 0.035), 0.005, sides=6, mi=CHR)       # cap screws
cyl(bm, uv, (0.0, -0.05, 0.022), (0.0, -0.066, 0.022), 0.006, sides=8, mi=CHR)       # clamp knob
cyl(bm, uv, (0.0, -0.066, 0.022), (0.0, -0.08, 0.022), 0.014, sides=10, mi=RUB)
cyl(bm, uv, (0, 0, 0.05), (0, 0, 0.058), 0.036, sides=16, mi=BLK)                    # tube flange
cyl(bm, uv, (0, 0, 0.058), (0, 0, 0.222), 0.025, sides=16, mi=ALU, vrep=0.6)         # outer tube
cyl(bm, uv, (0, 0, 0.222), (0, 0, 0.25), 0.029, sides=16, mi=BLK)                    # lock collar (top = 0.25)
box(bm, uv, 0.028, -0.005, 0.228, 0.05, 0.005, 0.244, mi=BLK)                        # collar lever
cyl(bm, uv, (0.05, 0, 0.236), (0.06, 0, 0.236), 0.008, sides=8, mi=RUB)
add(finish('opslabs_van_spot_post', bm, PARTS()), LOD)

# --- telescopic mast: inner tube Ø 40, 0.40 m, collar at the top. Origin = the TOP of the tube.
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, -0.40), (0, 0, -0.02), 0.02, sides=16, mi=ALU, vrep=1.5)
cyl(bm, uv, (0, 0, -0.40), (0, 0, -0.39), 0.0215, sides=16, mi=BLK)                  # bottom guide ring
cyl(bm, uv, (0, 0, -0.022), (0, 0, 0.0), 0.026, sides=16, mi=BLK)                    # top collar
add(finish('opslabs_van_spot_mast', bm, PARTS()), LOD)

# --- pan turntable + U-yoke. Origin = bottom centre of the turntable (pan axis Z). Arms at
#     x = +-0.15 (inner faces), tilt axis = X at z = 0.22, tilt motor housing on +X.
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, 0.0), (0, 0, 0.019), 0.06, sides=24, mi=BLK)                      # fixed base
cyl(bm, uv, (0, 0, 0.019), (0, 0, 0.021), 0.0605, sides=24, mi=ALU)                  # slew ring line
cyl(bm, uv, (0, 0, 0.021), (0, 0, 0.03), 0.057, sides=24, mi=BLK)                    # turning disc
cyl(bm, uv, (0, 0, 0.03), (0, 0, 0.038), 0.032, sides=16, mi=BLK)                    # hub
for s in (-1, 1):
    bar_xz(bm, uv, (s * 0.035, 0, 0.034), (s * 0.156, 0, 0.05), 0.007, 0.022, mi=BLK)    # low arm root (clear of the head)
    box(bm, uv, min(s * 0.150, s * 0.162), -0.022, 0.04, max(s * 0.150, s * 0.162), 0.022, 0.22, mi=BLK)  # arm
    cyl(bm, uv, (s * 0.150, 0, 0.22), (s * 0.162, 0, 0.22), 0.022, sides=16, mi=BLK)   # rounded arm top (pivot boss)
cyl(bm, uv, (0.162, 0, 0.22), (0.192, 0, 0.22), 0.03, sides=16, mi=BLK)              # tilt motor housing (+X)
cyl(bm, uv, (0.192, 0, 0.22), (0.195, 0, 0.22), 0.024, sides=16, mi=ALU)
cyl(bm, uv, (-0.162, 0, 0.22), (-0.172, 0, 0.22), 0.012, sides=10, mi=CHR)           # pivot cap (-X)
add(finish('opslabs_van_spot_yoke', bm, PARTS()), LOD)

# --- lamp head: Ø 0.22 body along +Y around the tilt pivot, chrome bezel + lens on +Y (lens face
#     y = 0.110, bezel lip 0.112), cooling fins on the back, trunnion stubs to x = +-0.15, handle on top
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, -0.09, 0), (0, 0.095, 0), 0.11, sides=28, mi=BLK)                    # body
cyl(bm, uv, (0, -0.092, 0), (0, -0.08, 0), 0.112, sides=28, mi=BLK)                  # rear rim
ring_y(bm, uv, 0.095, 0.112, 0.094, 0.115, mi=CHR, sides=48)                          # chrome bezel
disc_y(bm, uv, 0.110, 0.0945, mi=LNS, sides=28)                                       # glass + reflector
for k in range(-4, 5):                                                                # cooling fins
    x = k * 0.02
    hz = math.sqrt(max(0.0, 0.1 ** 2 - x ** 2)) * 0.95
    box(bm, uv, x - 0.0022, -0.118, -hz, x + 0.0022, -0.092, hz, mi=BLK)
cyl(bm, uv, (0, -0.06, -0.105), (0, -0.06, -0.125), 0.008, sides=8, mi=RUB)          # cable gland
for s in (-1, 1):
    cyl(bm, uv, (s * 0.105, 0, 0), (s * 0.15, 0, 0), 0.018, sides=12, mi=BLK)        # trunnion stub
    cyl(bm, uv, (s * 0.108, 0, 0), (s * 0.116, 0, 0), 0.026, sides=12, mi=CHR)       # trunnion flange
    cyl(bm, uv, (0, s * 0.05, 0.106), (0, s * 0.05, 0.142), 0.007, sides=8, mi=BLK)  # handle posts
cyl(bm, uv, (0, -0.062, 0.142), (0, 0.062, 0.142), 0.0095, sides=10, mi=RUB)         # handle grip
add(finish('opslabs_van_spot_head', bm, PARTS()), LOD)

# --- glowing lens only (same origin as the head), a hair in front of the glass
gbm = bmesh.new(); guv = gbm.loops.layers.uv.new('UVMap 0')
disc_y(gbm, guv, 0.1112, 0.093, mi=0, sides=28)
add(finish('opslabs_van_spot_head_on', gbm, [mat('opslabs_vs_glow', 'emissive.sps')]), LOD)

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
ytyp.name = 'opslabs_vanspot_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_vanspot.blend'))
