"""Lighting: San Andreas Power & Light street lights (galvanised columns with LED lanterns, a
lantern bracket for wooden power poles) and OPS Openline road works lighting (tripod twin-head
LED work light, towable lighting tower). Generic look, no real operator branding.
Every light has a matching `<name>_on` model holding only its glowing lenses, with the same
origin, so the client can spawn it on top of the light at night.
blender -b --python build_lighting.py -- <out_dir>
Columns / work lights: origin bottom centre, the lantern reaches out over -Y.
Pole bracket: origin = the pole surface behind it (y = 0), lantern out along -Y.
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
BLACK, YELLOW, WHITE = (24, 24, 26), (238, 186, 24), (240, 240, 236)
c = Canvas(64, 256, (158, 162, 165)); c.noise(10); save(c, 'opslabs_lt_galv')
# column base door: galvanised with a door outline, lock and a small ID plate
c = Canvas(64, 128, (158, 162, 165)); c.noise(10)
c.rect(14, 18, 50, 20, (110, 112, 114)); c.rect(14, 108, 50, 110, (110, 112, 114))
c.rect(14, 18, 16, 110, (110, 112, 114)); c.rect(48, 18, 50, 110, (110, 112, 114))
c.circle(32, 92, 3, (60, 60, 62))
c.rect(20, 30, 44, 50, (250, 214, 30)); text(c, 'SAPL', 21, 32, 1, BLACK); text(c, '147', 23, 41, 1, BLACK)
save(c, 'opslabs_lt_door')
c = Canvas(64, 64, (62, 66, 70)); c.noise(5); save(c, 'opslabs_lt_body')          # lantern housing (dark grey)
c = Canvas(64, 64, BLACK); c.noise(4); save(c, 'opslabs_lt_black')
c = Canvas(64, 64, YELLOW); c.noise(5); save(c, 'opslabs_lt_yellow')
c = Canvas(32, 128, (230, 180, 20)); c.noise(6); save(c, 'opslabs_lt_cable')       # 110 V site cable


def lens(name, base, led, glow=False):
    """LED array: a grid of emitters on a frosted panel"""
    c = Canvas(128, 128, base)
    for y in range(8, 128, 16):
        for x in range(8, 128, 16):
            c.circle(x, y, 5, led)
            if glow:
                c.circle(x, y, 3, tuple(min(255, v + 30) for v in led))
    save(c, name)


lens('opslabs_lt_lens', (150, 154, 158), (190, 194, 198))                                  # off: grey frosted
lens('opslabs_lt_glow_warm', (255, 214, 160), (255, 246, 226), glow=True)                  # street (≈ 4000 K)
lens('opslabs_lt_glow_cool', (210, 226, 255), (250, 252, 255), glow=True)                  # work lights (≈ 5700 K)
# lighting tower body: plant yellow with a black chevron band and OPS OPENLINE on the side
c = Canvas(512, 256, YELLOW); c.noise(5)
c.rect(0, 200, 512, 256, BLACK)
for x in range(-64, 512, 48):
    for y in range(204, 252):
        x0 = x + (y - 204)
        c.rect(x0, y, x0 + 22, y + 1, YELLOW)
c.rect(0, 196, 512, 200, BLACK)
centered(c, 'OPS OPENLINE', 60, 7, BLACK)
centered(c, 'LIGHTING TOWER', 130, 4, BLACK)
save(c, 'opslabs_lt_tower_body')

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
LIGHTS = {}    # model -> [(x, y, z, pitch_deg)] emitter centres, for Config.Lighting


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- LED street lantern: flat housing on the end of an arm, lens underneath
def lantern(bm, uv, glow_bm, glow_uv, ye, ze, side=-1):
    """arm ends at (0, ye, ze); the lantern reaches on out along `side` (-1 → -Y, +1 → +Y)"""
    y0, y1 = ye, ye + side * 0.62
    lo, hi = sorted((y0, y1))
    zb = ze - 0.06
    box(bm, uv, -0.15, lo, zb, 0.15, hi, zb + 0.10, mi=2)                                      # housing
    box(bm, uv, -0.12, lo + 0.04, zb + 0.10, 0.12, hi - 0.04, zb + 0.13, mi=2)                # cooling fins / top
    box(bm, uv, -0.12, lo + 0.06, zb - 0.012, 0.12, hi - 0.06, zb, mi=2, bottom=3)            # lens tray
    cy = (lo + hi) / 2
    quad(glow_bm, glow_uv, (0, cy, zb - 0.016), 0.24, (hi - lo) - 0.12, 0, mi=0, down=True)
    return (0.0, round(cy, 3), round(zb - 0.02, 3), 90)


def arm(bm, uv, z0, reach, rise, side=-1, r=0.04):
    """curved outreach bracket from the column top: leaves it going up, ends level (quarter ellipse)"""
    pts = []
    for k in range(7):
        a = k / 6 * math.pi / 2
        pts.append((0.0, side * reach * (1 - math.cos(a)), z0 + rise * math.sin(a)))
    for p, q in zip(pts, pts[1:]):
        cyl(bm, uv, p, q, r, sides=10, mi=0)
    return pts[-1]


def column(name, H, reach, twin=False):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    gbm = bmesh.new(); guv = gbm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -0.16, -0.16, 0.0, 0.16, 0.16, 0.02, mi=0)                                     # root flange / base plate
    cyl(bm, uv, (0, 0, 0.02), (0, 0, 1.3), 0.105, 0.10, sides=16, mi=0, vrep=1.0)            # base compartment
    box(bm, uv, -0.06, 0.06, 0.25, 0.06, 0.107, 1.10, mi=0, back=1)                           # door (footpath side)
    cyl(bm, uv, (0, 0, 1.3), (0, 0, 1.36), 0.10, 0.07, sides=16, mi=0)                        # shoulder
    cyl(bm, uv, (0, 0, 1.36), (0, 0, H), 0.07, 0.05, sides=16, mi=0, vrep=H / 2)             # shaft
    pts = []
    for side in ((-1, 1) if twin else (-1,)):
        _, ye, ze = arm(bm, uv, H, reach, 0.35, side)
        pts.append(lantern(bm, uv, gbm, guv, ye, ze, side))
    cyl(bm, uv, (0, 0, H), (0, 0, H + 0.06), 0.05, 0.0, sides=12, mi=0)                       # cap
    add(finish(name, bm, [mat('opslabs_lt_galv'), mat('opslabs_lt_door'), mat('opslabs_lt_body'), mat('opslabs_lt_lens')]), 350.0, 'METAL_SOLID_MEDIUM')
    add(finish(name + '_on', gbm, [mat('opslabs_lt_glow_warm', 'emissive.sps')]), 350.0)
    LIGHTS[name] = pts


column('opslabs_streetlight_6m', 6.0, 1.0)
column('opslabs_streetlight_10m', 10.0, 1.5)
column('opslabs_streetlight_10m_twin', 10.0, 1.5, twin=True)

# --- lantern bracket for a wooden power pole: two clamp bands, a raked tube and the lantern
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
gbm = bmesh.new(); guv = gbm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.08, -0.06, 0.0, 0.08, 0.0, 0.40, mi=0)                                          # backing plate
for z in (0.06, 0.32):                                                                         # bands round the pole
    box(bm, uv, -0.13, -0.02, z, 0.13, 0.0, z + 0.03, mi=0)
cyl(bm, uv, (0, -0.06, 0.12), (0, -0.55, 0.40), 0.03, sides=10, mi=0)                         # tube
cyl(bm, uv, (0, -0.55, 0.40), (0, -1.10, 0.52), 0.03, sides=10, mi=0)
cyl(bm, uv, (0, -0.06, 0.34), (0, -0.55, 0.40), 0.015, sides=6, mi=0)                         # stay
pts = [lantern(bm, uv, gbm, guv, -1.10, 0.52)]
add(finish('opslabs_streetlight_pole', bm, [mat('opslabs_lt_galv'), mat('opslabs_lt_door'), mat('opslabs_lt_body'), mat('opslabs_lt_lens')]), 300.0, 'METAL_SOLID_SMALL')
add(finish('opslabs_streetlight_pole_on', gbm, [mat('opslabs_lt_glow_warm', 'emissive.sps')]), 300.0)
LIGHTS['opslabs_streetlight_pole'] = pts


# --- LED flood head: yellow die-cast body, black fins, lens on the front, tilted down
def flood(bm, uv, gbm, guv, x, y, z, w, h, d, pitch_deg):
    p = math.radians(pitch_deg)
    obox(bm, uv, (x, y, z), (w, d, h), p, mi=1, front=3)                                       # body, lens on front
    obox(bm, uv, (x, y + d * math.cos(p) * 0.75, z + d * math.sin(p) * 0.75), (w * 0.9, d * 0.5, h * 0.9), p, mi=2)  # fins
    rot = mathutils.Matrix.Rotation(p, 3, 'X')
    fc = mathutils.Vector((x, y, z)) + rot @ mathutils.Vector((0, -d / 2 - 0.004, 0))
    quad(gbm, guv, tuple(fc), w * 0.86, h * 0.84, p, mi=0)
    # yoke: two side straps to the bar
    for sx in (-1, 1):
        box(bm, uv, x + sx * (w / 2 + 0.005) - 0.006, y - 0.02, z - 0.02, x + sx * (w / 2 + 0.005) + 0.006, y + 0.02, z + h * 0.6, mi=0)
    return (round(fc.x, 3), round(fc.y, 3), round(fc.z, 3), pitch_deg)


# --- tripod work light: 3 legs, telescopic mast to 2.3 m, T-bar with two 50 W LED floods,
#     110 V cable down to a yellow site transformer at the foot
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
gbm = bmesh.new(); guv = gbm.loops.layers.uv.new('UVMap 0')
hub = 0.95
for k in range(3):
    a = math.radians(90 + k * 120)
    fx, fy = 0.55 * math.cos(a), 0.55 * math.sin(a)
    cyl(bm, uv, (fx, fy, 0.0), (0, 0, hub), 0.014, sides=8, mi=0)
    cyl(bm, uv, (fx, fy, 0.0), (fx, fy, 0.03), 0.025, sides=8, mi=2)                          # rubber feet
    cyl(bm, uv, (fx * 0.45, fy * 0.45, hub * 0.55), (0, 0, hub * 0.75), 0.008, sides=6, mi=0)  # leg braces
cyl(bm, uv, (0, 0, hub - 0.05), (0, 0, hub + 0.08), 0.03, sides=10, mi=2)                      # hub clamp
cyl(bm, uv, (0, 0, hub), (0, 0, 1.65), 0.022, sides=10, mi=0)                                  # lower mast
cyl(bm, uv, (0, 0, 1.62), (0, 0, 1.68), 0.03, sides=10, mi=2)                                  # height clamp
cyl(bm, uv, (0, 0, 1.65), (0, 0, 2.30), 0.017, sides=10, mi=0)                                 # upper mast
cyl(bm, uv, (-0.42, 0, 2.30), (0.42, 0, 2.30), 0.016, sides=8, mi=0)                           # T-bar
pts = [flood(bm, uv, gbm, guv, sx * 0.24, -0.06, 2.24, 0.30, 0.22, 0.07, 25) for sx in (-1, 1)]
cyl(bm, uv, (0.03, 0.0, 2.25), (0.03, 0.0, hub), 0.006, sides=6, mi=4)                         # cable down the mast
cyl(bm, uv, (0.03, 0.0, hub), (0.45, -0.35, 0.02), 0.006, sides=6, mi=4)
box(bm, uv, 0.35, -0.55, 0.0, 0.62, -0.36, 0.22, mi=1)                                         # 110 V transformer
cyl(bm, uv, (0.40, -0.455, 0.22), (0.57, -0.455, 0.22), 0.012, sides=6, mi=2)                  # handle
add(finish('opslabs_rw_worklight', bm, [mat('opslabs_lt_galv'), mat('opslabs_lt_yellow'), mat('opslabs_lt_black'), mat('opslabs_lt_lens'), mat('opslabs_lt_cable')]), 200.0, 'METAL_SOLID_SMALL')
add(finish('opslabs_rw_worklight_on', gbm, [mat('opslabs_lt_glow_cool', 'emissive.sps')]), 200.0)
LIGHTS['opslabs_rw_worklight'] = pts

# --- lighting tower: single-axle trailer (2.4 × 1.3 m canopy), 4 outriggers, 3-stage mast to
#     7.5 m with a bar of four LED floods facing -Y
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
gbm = bmesh.new(); guv = gbm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -1.2, -0.65, 0.42, 1.2, 0.65, 0.50, mi=0)                                          # chassis
box(bm, uv, -1.15, -0.62, 0.50, 1.15, 0.62, 1.55, mi=1, front=5, back=5)                       # canopy (branded sides)
box(bm, uv, -1.12, -0.60, 1.55, 1.12, 0.60, 1.60, mi=1)                                        # roof lip
for sy in (-1, 1):                                                                             # wheels + mudguards
    cyl(bm, uv, (0.0, sy * 0.62, 0.30), (0.0, sy * 0.80, 0.30), 0.30, sides=16, mi=2)
    box(bm, uv, -0.38, sy * 0.62 if sy > 0 else -0.82, 0.62, 0.38, 0.82 if sy > 0 else -0.62, 0.65, mi=0)
cyl(bm, uv, (-1.2, -0.4, 0.46), (-2.1, 0.0, 0.46), 0.04, sides=8, mi=0)                        # A-frame drawbar
cyl(bm, uv, (-1.2, 0.4, 0.46), (-2.1, 0.0, 0.46), 0.04, sides=8, mi=0)
cyl(bm, uv, (-2.1, 0.0, 0.46), (-2.25, 0.0, 0.46), 0.045, sides=10, mi=2)                      # hitch
cyl(bm, uv, (-1.9, 0.0, 0.46), (-1.9, 0.0, 0.0), 0.025, sides=8, mi=0)                         # jockey wheel post
cyl(bm, uv, (-1.92, 0.0, 0.07), (-1.88, 0.0, 0.07), 0.07, sides=12, mi=2)
for sx in (-1, 1):                                                                             # outriggers + jacks
    for sy in (-1, 1):
        cyl(bm, uv, (sx * 1.0, sy * 0.55, 0.46), (sx * 1.45, sy * 1.25, 0.46), 0.035, sides=8, mi=1)
        cyl(bm, uv, (sx * 1.45, sy * 1.25, 0.46), (sx * 1.45, sy * 1.25, 0.04), 0.025, sides=8, mi=0)
        box(bm, uv, sx * 1.45 - 0.1, sy * 1.25 - 0.1, 0.0, sx * 1.45 + 0.1, sy * 1.25 + 0.1, 0.04, mi=0)
cyl(bm, uv, (0.6, 0, 1.60), (0.6, 0, 4.0), 0.08, sides=12, mi=0)                               # mast: 3 stages
cyl(bm, uv, (0.6, 0, 3.95), (0.6, 0, 5.8), 0.065, sides=12, mi=0)
cyl(bm, uv, (0.6, 0, 5.75), (0.6, 0, 7.5), 0.05, sides=12, mi=0)
for z in (4.0, 5.8):
    cyl(bm, uv, (0.6, 0, z - 0.03), (0.6, 0, z + 0.03), 0.09 if z < 5 else 0.075, sides=12, mi=2)
cyl(bm, uv, (0.6 - 0.85, 0, 7.5), (0.6 + 0.85, 0, 7.5), 0.035, sides=8, mi=0)                 # light bar
pts = [flood(bm, uv, gbm, guv, 0.6 + x, -0.09, 7.42, 0.40, 0.32, 0.08, 20) for x in (-0.66, -0.22, 0.22, 0.66)]
cyl(bm, uv, (0.62, 0.06, 7.45), (0.62, 0.06, 1.60), 0.01, sides=6, mi=2)                       # coiled feed cable
box(bm, uv, -1.16, -0.35, 0.75, -1.15, 0.35, 1.30, mi=2)                                       # control panel door (drawbar end)
add(finish('opslabs_rw_lighttower', bm, [mat('opslabs_lt_galv'), mat('opslabs_lt_yellow'), mat('opslabs_lt_black'), mat('opslabs_lt_lens'), mat('opslabs_lt_cable'), mat('opslabs_lt_tower_body')]), 400.0, 'METAL_SOLID_MEDIUM')
add(finish('opslabs_rw_lighttower_on', gbm, [mat('opslabs_lt_glow_cool', 'emissive.sps')]), 400.0)
LIGHTS['opslabs_rw_lighttower'] = pts

for k, v in LIGHTS.items():
    print('LIGHTS', k, v)

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
ytyp.name = 'opslabs_lighting_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_lighting.blend'))
