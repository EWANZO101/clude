"""Rigging: guild wire (galvanised 7/4.0 steel strand) pieces + joint, the forged pole hook it
sits in, and the climber's harness kit: orange pole strap (fits round any pole) and a 1 m
lanyard strip that the client stretches between the harness and the strap.
blender -b --python build_rigging.py -- <out_dir>
Strand pieces: along +Y from the origin (like the cable pieces). Hook: origin = pole surface
(y = 0), the hook reaches out along -Y; the wire rests at (0, -0.055, 0). Strap: origin = pole
centre. Lanyard: 1 m along +Y, origin at one end.
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

FONT = {
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], 'P': ['11110', '10001', '10001', '11110', '10000', '10000', '10000'],
    'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'], 'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
    'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'], 'L': ['10000', '10000', '10000', '10000', '10000', '10000', '11111'],
    'I': ['01110', '00100', '00100', '00100', '00100', '00100', '01110'], 'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    '0': ['01110', '10011', '10101', '10101', '11001', '10001', '01110'], '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
    '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'], '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
    'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01111'], 'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], 'W': ['10001', '10001', '10001', '10101', '10101', '10101', '01010'],
    'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    ' ': ['00000'] * 7, '-': ['00000', '00000', '00000', '11111', '00000', '00000', '00000'],
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
    text(c, s, (c.w - (len(s) * 6 * px - px)) // 2, y, px, color)


def save(c, name):
    c.save_dds(os.path.join(TEX, name + '.dds'))



# ---------------------------------------------------------------- textures
c = Canvas(64, 64, (170, 174, 176)); c.noise(14)
for y in range(0, 64, 8):                       # strand lay lines
    for x in range(64):
        c.rect(x, (y + x // 4) % 64, x + 1, (y + x // 4) % 64 + 1, (120, 124, 128))
save(c, 'opslabs_rg_strand')
c = Canvas(64, 64, (150, 154, 158)); c.noise(10); save(c, 'opslabs_rg_galv')
c = Canvas(64, 32, (240, 110, 20)); c.noise(6)
for x in range(0, 64, 4): c.rect(x, 0, x + 1, 32, (210, 90, 14))                # webbing weave
c.rect(0, 0, 64, 3, (40, 40, 42)); c.rect(0, 29, 64, 32, (40, 40, 42))           # black edge stitching
save(c, 'opslabs_rg_webbing')
c = Canvas(32, 32, (60, 62, 66)); c.noise(6); save(c, 'opslabs_rg_steel')

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


def obox(bm, uv, centre, size, pitch=0.0, mi=0, front=None):
    """box of size (w, d, h) round `centre`, tilted `pitch` radians so its -Y face looks down"""
    w, d, h = (s / 2 for s in size)
    rot = mathutils.Matrix.Rotation(pitch, 3, 'X')
    cv = mathutils.Vector(centre)

    def P(x, y, z):
        return bm.verts.new(cv + rot @ mathutils.Vector((x, y, z)))
    F = {
        'front': [(-w, -d, -h), (w, -d, -h), (w, -d, h), (-w, -d, h)],
        'back': [(w, d, -h), (-w, d, -h), (-w, d, h), (w, d, h)],
        'left': [(-w, d, -h), (-w, -d, -h), (-w, -d, h), (-w, d, h)],
        'right': [(w, -d, -h), (w, d, -h), (w, d, h), (w, -d, h)],
        'top': [(-w, -d, h), (w, -d, h), (w, d, h), (-w, d, h)],
        'bottom': [(-w, d, -h), (w, d, -h), (w, -d, -h), (-w, -d, -h)],
    }
    for k, vs in F.items():
        f = bm.faces.new([P(*v) for v in vs])
        f.material_index = front if (k == 'front' and front is not None) else mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


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


def quad(bm, uv, centre, w, h, pitch, mi=0, down=False):
    """flat emitter: w × h, facing -Y tilted down by `pitch` (or straight down when `down`)"""
    rot = mathutils.Matrix.Rotation(pitch, 3, 'X')
    cv = mathutils.Vector(centre)
    if down:   # in the XY plane, normal -Z
        vs = [(-w / 2, h / 2, 0), (w / 2, h / 2, 0), (w / 2, -h / 2, 0), (-w / 2, -h / 2, 0)]
        pts = [cv + mathutils.Vector(v) for v in vs]
    else:      # in the XZ plane, normal -Y
        vs = [(-w / 2, 0, -h / 2), (w / 2, 0, -h / 2), (w / 2, 0, h / 2), (-w / 2, 0, h / 2)]
        pts = [cv + rot @ mathutils.Vector(v) for v in vs]
    f = bm.faces.new([bm.verts.new(p) for p in pts])
    f.material_index = mi
    for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop[uv].uv = u



models = []    # (obj, lod, collision)


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- guy strand pieces (Ø 7 mm) + joint ball
R = 0.0035
for cm in (5, 10, 25, 50, 100, 200):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    cyl(bm, uv, (0, 0, 0), (0, cm / 100, 0), R, sides=8, mi=0, vrep=cm / 100 * 8)
    add(finish(f'opslabs_guy_seg_{cm:03d}', bm, [mat('opslabs_rg_strand')]), 120.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=R * 1.1)
for f in bm.faces:
    for loop in f.loops: loop[uv].uv = (0.5, 0.5)
add(finish('opslabs_guy_joint', bm, [mat('opslabs_rg_strand')]), 120.0)

# --- forged pole hook on a back plate (two coach screws), wire seat at (0, -0.055, 0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.035, -0.012, -0.07, 0.035, 0.0, 0.07, mi=0)                    # back plate
for z in (-0.045, 0.045):
    cyl(bm, uv, (0, -0.012, z), (0, -0.022, z), 0.011, sides=6, mi=1)          # screw heads
cz = 0.0085                                                                   # J centre: wire (r 3.5 mm) rests at z = 0
cyl(bm, uv, (0, -0.012, cz), (0, -0.043, cz), 0.0045, sides=8, mi=0)          # shank
pts = [(0, -0.055 + 0.012 * math.cos(math.pi * k / 8), cz - 0.012 * math.sin(math.pi * k / 8)) for k in range(9)]
for p0, p1 in zip(pts, pts[1:]):
    cyl(bm, uv, p0, p1, 0.0045, sides=8, mi=0)                                # the J
cyl(bm, uv, pts[-1], (0, -0.067, cz + 0.03), 0.0045, sides=8, mi=0)           # tip, up
add(finish('opslabs_guy_hook', bm, [mat('opslabs_rg_galv'), mat('opslabs_rg_steel')]), 120.0)

# --- harness pole strap: webbing loop (r 0.16, fits any pole) with a D-ring + karabiner at -Y
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
ring_r, n = 0.16, 20
for i in range(n):
    a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
    for rr, flip in ((ring_r, False), (ring_r - 0.004, True)):
        vs = [(rr * math.cos(a0), rr * math.sin(a0), -0.0225), (rr * math.cos(a1), rr * math.sin(a1), -0.0225),
              (rr * math.cos(a1), rr * math.sin(a1), 0.0225), (rr * math.cos(a0), rr * math.sin(a0), 0.0225)]
        if flip: vs.reverse()
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = 0
        for loop, u in zip(f.loops, ((i / n * 4, 0), ((i + 1) / n * 4, 0), ((i + 1) / n * 4, 1), (i / n * 4, 1))):
            loop[uv].uv = u
for k in range(10):                                                            # D-ring
    a0, a1 = math.pi * k / 10, math.pi * (k + 1) / 10
    cyl(bm, uv, (0.03 * math.cos(a0), -ring_r - 0.035 * math.sin(a0), 0), (0.03 * math.cos(a1), -ring_r - 0.035 * math.sin(a1), 0), 0.004, sides=6, mi=1)
cyl(bm, uv, (-0.03, -ring_r, 0), (0.03, -ring_r, 0), 0.004, sides=6, mi=1)
add(finish('opslabs_harness_strap', bm, [mat('opslabs_rg_webbing'), mat('opslabs_rg_steel')]), 60.0)

# --- lanyard: 1 m strip of webbing along +Y (the client stretches it with the entity matrix)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.016, 0.0, -0.004, 0.016, 1.0, 0.004, mi=0)
add(finish('opslabs_lanyard', bm, [mat('opslabs_rg_webbing')]), 60.0)

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
ytyp.name = 'opslabs_rigging_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_rigging.blend'))
