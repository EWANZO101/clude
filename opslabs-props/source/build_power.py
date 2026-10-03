"""Power network (San Andreas Power & Light), alt-net (StreamFibre) kit, branded metal pole and
extra OPS Openline pole hardware. Generic look, no real operator branding.
blender -b --python build_power.py -- <out_dir>
Pole-mounted kit: origin = the pole surface behind it (y = 0), front -Y. Poles / floor kit: bottom centre.
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
    'D': ['11110', '10001', '10001', '10001', '10001', '10001', '11110'], 'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
    'N': ['10001', '11001', '10101', '10011', '10001', '10001', '10001'], 'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01111'],
    'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'], 'R': ['11110', '10001', '10001', '11110', '10100', '10010', '10001'],
    'O': ['01110', '10001', '10001', '10001', '10001', '10001', '01110'], 'F': ['11111', '10000', '10000', '11110', '10000', '10000', '10000'],
    'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'], 'H': ['10001', '10001', '10001', '11111', '10001', '10001', '10001'],
    'S': ['01111', '10000', '10000', '01110', '00001', '00001', '11110'], '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
    '2': ['01110', '10001', '00001', '00010', '00100', '01000', '11111'], '0': ['01110', '10011', '10101', '10101', '11001', '10001', '01110'],
    '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'], '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
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
import random
rnd = random.Random(5)
c = Canvas(128, 512, (88, 66, 44))
for x in range(128):
    sh = rnd.randint(-12, 10); c.rect(x, 0, x + 1, 512, (88 + sh, 66 + sh, 44 + sh // 2))
c.noise(5); save(c, 'opslabs_pwr_wood')
c = Canvas(64, 64, (150, 154, 158)); c.noise(10); save(c, 'opslabs_pwr_galv')
c = Canvas(64, 64, (128, 132, 128)); c.noise(6); save(c, 'opslabs_pwr_grey')
c = Canvas(64, 64, (130, 92, 44)); c.noise(6); save(c, 'opslabs_pwr_porcelain')      # brown glazed insulators
c = Canvas(64, 64, (22, 22, 24)); c.noise(3); save(c, 'opslabs_pwr_black')
c = Canvas(64, 64, (184, 115, 51)); c.noise(8); save(c, 'opslabs_pwr_copper')
c = Canvas(16, 256, (175, 178, 182)); c.noise(6); save(c, 'opslabs_power_hv')            # bare aluminium conductor
c = Canvas(16, 256, (26, 26, 28))
for y in range(0, 256, 16):
    c.rect(0, y, 16, y + 2, (40, 40, 44))
c.noise(2); save(c, 'opslabs_power_lv')                                                  # twisted ABC bundle
c = Canvas(16, 256, (20, 20, 22)); c.noise(2); save(c, 'opslabs_power_service')
c = Canvas(128, 160, (250, 214, 30))                                                     # Danger of Death sign
c.rect(0, 0, 128, 6, (20, 20, 20)); c.rect(0, 154, 128, 160, (20, 20, 20)); c.rect(0, 0, 6, 160, (20, 20, 20)); c.rect(122, 0, 128, 160, (20, 20, 20))
for k in range(5):                                                                       # lightning bolt
    c.rect(54 + k * 4 - (k > 2) * 10, 14 + k * 10, 70 + k * 4 - (k > 2) * 10, 24 + k * 10, (20, 20, 20))
centered(c, 'DANGER', 78, 3, (20, 20, 20)); centered(c, 'OF DEATH', 104, 2, (20, 20, 20)); centered(c, 'HIGH', 128, 2, (20, 20, 20))
save(c, 'opslabs_pwr_danger')
c = Canvas(64, 64, (250, 214, 30)); centered(c, 'SF', 22, 3, (20, 20, 20)); save(c, 'opslabs_alt_tag')      # alt-net ID tag
c = Canvas(64, 64, (236, 238, 240)); c.noise(2); save(c, 'opslabs_alt_white')
c = Canvas(16, 16, (20, 160, 170)); c.noise(2); save(c, 'opslabs_alt_cap')
# metal pole branding plates (default face; replaced live per pole)
for n in range(1, 9):
    c = Canvas(256, 352, (245, 245, 243))
    c.rect(0, 0, 256, 70, (10, 132, 255)); centered(c, 'OPS', 20, 5, (255, 255, 255))
    centered(c, 'POLE 0001', 150, 3, (20, 20, 22))
    c.noise(2); save(c, f'opslabs_brandplate_{n}')

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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None):
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
        f.material_index = front if (k == 'front' and front is not None) else mi
        for loop, u in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
            loop[uv].uv = u


def cyl(bm, uv, p0, p1, r0, r1=None, sides=12, mi=0, vrep=1.0):
    import mathutils
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


def insulator(bm, uv, x, y, z, mi):
    """pin insulator: stacked sheds"""
    cyl(bm, uv, (x, y, z), (x, y, z + 0.03), 0.006, sides=6, mi=1)
    for k in range(3):
        cyl(bm, uv, (x, y, z + 0.03 + k * 0.035), (x, y, z + 0.06 + k * 0.035), 0.045 - k * 0.008, 0.02, sides=12, mi=mi)


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- wooden power poles with a cross-arm, three pin insulators and an LV rack lower down
for H in (10, 12):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    rb, rt = 0.14, 0.09
    cyl(bm, uv, (0, 0, 0), (0, 0, H), rb, rt, sides=16, mi=0, vrep=H / 2)
    box(bm, uv, -1.0, -0.05, H - 0.5, 1.0, 0.05, H - 0.4, mi=1)                      # galvanised cross-arm
    for x in (-0.9, 0.0, 0.9):
        insulator(bm, uv, x, 0.0, H - 0.4, 2)
    for sx in (-1, 1):                                                                # cross-arm braces
        cyl(bm, uv, (0, 0, H - 1.1), (sx * 0.6, 0, H - 0.5), 0.015, sides=6, mi=1)
    box(bm, uv, -0.06, -0.20, H - 2.0, 0.06, -0.10, H - 1.4, mi=1)                   # LV rack bracket
    for k in range(4):
        insulator(bm, uv, 0.0, -0.22, H - 1.95 + k * 0.15, 2)
    for k in range(int((H - 3.0) / 0.45)):                                            # step bolts
        z = 2.5 + k * 0.45
        s = 1 if k % 2 else -1
        cyl(bm, uv, (s * rb * 0.6, 0, z), (s * (rb * 0.6 + 0.16), 0, z), 0.01, sides=6, mi=1)
    add(finish(f'opslabs_power_pole_{H}m', bm, [mat('opslabs_pwr_wood'), mat('opslabs_pwr_galv'), mat('opslabs_pwr_porcelain')]), 300.0, 'WOOD_SOLID_MEDIUM')

# --- pole-mounted transformer: grey tank, cooling fins, three HV bushings on top
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.04, -0.08, 0.6, 0.04, 0.0, 0.7, mi=1)                                 # hanger bracket
cyl(bm, uv, (0, -0.42, 0.0), (0, -0.42, 0.85), 0.34, sides=20, mi=0)
for k in range(10):
    a = 2 * math.pi * k / 10
    box(bm, uv, 0.34 * math.cos(a) - 0.01, -0.42 + 0.34 * math.sin(a) - 0.01, 0.1, 0.34 * math.cos(a) + 0.01 + 0.06 * math.cos(a), -0.42 + 0.34 * math.sin(a) + 0.01 + 0.06 * math.sin(a), 0.7, mi=0)
for x in (-0.15, 0.0, 0.15):
    insulator(bm, uv, x, -0.42, 0.85, 2)
add(finish('opslabs_power_transformer', bm, [mat('opslabs_pwr_grey'), mat('opslabs_pwr_galv'), mat('opslabs_pwr_porcelain')]), 200.0, 'METAL_SOLID_MEDIUM')

# --- cut-out fuses & surge arresters: bracket with three fuse tubes and three arresters
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.6, -0.12, 0.0, 0.6, -0.04, 0.08, mi=1)
box(bm, uv, -0.04, -0.04, 0.0, 0.04, 0.0, 0.08, mi=1)
for i, x in enumerate((-0.45, 0.0, 0.45)):
    cyl(bm, uv, (x, -0.14, 0.08), (x + 0.05, -0.18, 0.42), 0.025, sides=10, mi=3)    # fuse tube
    insulator(bm, uv, x + 0.14, -0.12, 0.08, 2)                                       # arrester
add(finish('opslabs_power_cutouts', bm, [mat('opslabs_pwr_grey'), mat('opslabs_pwr_galv'), mat('opslabs_pwr_porcelain'), mat('opslabs_pwr_black')]), 150.0)

# --- pole-mounted auto-recloser: control box + switch tank with bushings
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.05, -0.08, 0.3, 0.05, 0.0, 0.4, mi=1)
box(bm, uv, -0.35, -0.55, 0.0, 0.35, -0.1, 0.45, mi=0)
for x in (-0.22, 0.0, 0.22):
    insulator(bm, uv, x, -0.33, 0.45, 2)
box(bm, uv, -0.18, -0.12, -0.8, 0.18, -0.02, -0.4, mi=0)                             # control cabinet lower down
add(finish('opslabs_power_recloser', bm, [mat('opslabs_pwr_grey'), mat('opslabs_pwr_galv'), mat('opslabs_pwr_porcelain')]), 150.0)

# --- cable termination box ("pothead"): underground cable up the pole into a sealing end
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, -0.08, 0.0), (0, -0.08, 2.0), 0.05, sides=10, mi=3)                  # cable guard up the pole
box(bm, uv, -0.14, -0.22, 2.0, 0.14, 0.0, 2.4, mi=0)
for x in (-0.08, 0.0, 0.08):
    insulator(bm, uv, x, -0.11, 2.4, 2)
add(finish('opslabs_power_pothead', bm, [mat('opslabs_pwr_grey'), mat('opslabs_pwr_galv'), mat('opslabs_pwr_porcelain'), mat('opslabs_pwr_black')]), 150.0)

# --- LV line connectors & shrouds: small spool rack
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.03, -0.06, 0.0, 0.03, 0.0, 0.5, mi=1)
for k in range(4):
    z = 0.06 + k * 0.12
    cyl(bm, uv, (0, -0.06, z), (0, -0.14, z), 0.02, sides=10, mi=1)
    cyl(bm, uv, (0, -0.14, z), (0, -0.18, z), 0.035, sides=12, mi=2)                 # shroud spool
add(finish('opslabs_power_lv_connectors', bm, [mat('opslabs_pwr_black'), mat('opslabs_pwr_galv'), mat('opslabs_pwr_porcelain')]), 100.0)

# --- copper earth tape: a 3.5 m strap down the pole surface
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.012, -0.003, 0.0, 0.012, 0.0, 3.5, mi=0)
add(finish('opslabs_power_earth_tape', bm, [mat('opslabs_pwr_copper')]), 80.0)

# --- anti-climbing device: spiked band round the pole (centred on the pole axis)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, 0.0), (0, 0, 0.35), 0.16, sides=20, mi=0)
for k in range(24):
    a = 2 * math.pi * k / 24
    for z in (0.08, 0.27):
        cyl(bm, uv, (0.16 * math.cos(a), 0.16 * math.sin(a), z), (0.26 * math.cos(a), 0.26 * math.sin(a), z + 0.04), 0.006, 0.0005, sides=5, mi=0)
add(finish('opslabs_power_anticlimb', bm, [mat('opslabs_pwr_galv')]), 80.0)

# --- danger of death sign plate
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.12, -0.006, 0.0, 0.12, 0.0, 0.30, mi=0, front=1)
add(finish('opslabs_power_danger_sign', bm, [mat('opslabs_pwr_galv'), mat('opslabs_pwr_danger')]), 60.0)

# --- power cable segments (run along +Y): bare HV, LV ABC bundle, black service drop
for colour, radius in (('hv', 0.006), ('lv', 0.011), ('service', 0.005)):
    for cm in (5, 10, 25, 50, 100, 200):
        bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
        cyl(bm, uv, (0, 0, 0), (0, cm / 100, 0), radius, sides=8, mi=0, vrep=cm / 100 * 4)
        add(finish(f'opslabs_power_{colour}_{cm:03d}', bm, [mat('opslabs_power_' + colour)]), 120.0)
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=radius * 1.05)
    for f in bm.faces:
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    add(finish(f'opslabs_power_{colour}_joint', bm, [mat('opslabs_power_' + colour)]), 120.0)

# --- branded metal pole: 9 m galvanised octagonal pole with step bolts; the information plate
#     is a separate prop (8 variants, each with its own live face texture)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, 0), (0, 0, 9.0), 0.11, 0.065, sides=8, mi=0, vrep=4)
cyl(bm, uv, (0, 0, 8.72), (0, 0, 8.78), 0.075, sides=8, mi=0, vrep=0.2)            # ring head
box(bm, uv, -0.2, -0.2, 0.0, 0.2, 0.2, 0.03, mi=0)                                   # base plate
for k in range(int(6.0 / 0.4)):
    z = 2.8 + k * 0.4
    s = 1 if k % 2 else -1
    cyl(bm, uv, (s * 0.06, 0, z), (s * 0.2, 0, z), 0.009, sides=6, mi=0)
add(finish('opslabs_pole_metal', bm, [mat('opslabs_pwr_galv')]), 300.0, 'METAL_SOLID_MEDIUM')
for n in range(1, 9):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -0.25, -0.012, 0.0, 0.25, 0.0, 0.69, mi=1, front=0)
    add(finish(f'opslabs_brandplate_{n}', bm, [mat(f'opslabs_brandplate_{n}'), mat('opslabs_pwr_galv')]), 100.0)

# --- alt-net (StreamFibre): white CBT with teal caps, yellow ID tag, shared PIA bracket
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.03, -0.006, 0.06, 0.03, 0.0, 0.30, mi=1)
box(bm, uv, -0.018, -0.07, 0.10, 0.018, -0.006, 0.12, mi=1)
box(bm, uv, -0.018, -0.07, 0.24, 0.018, -0.006, 0.26, mi=1)
box(bm, uv, -0.08, -0.22, 0.06, 0.08, -0.07, 0.34, mi=0)
for k in range(8):
    x = -0.06 + (k % 4) * 0.04
    zz = 0.03 if k < 4 else 0.0
    cyl(bm, uv, (x, -0.16, 0.06 - zz), (x, -0.16, 0.03 - zz), 0.01, sides=8, mi=2)
add(finish('opslabs_alt_cbt', bm, [mat('opslabs_alt_white'), mat('opslabs_pwr_galv'), mat('opslabs_alt_cap')]), 120.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.04, -0.004, 0.0, 0.04, 0.0, 0.06, mi=1, front=0)
add(finish('opslabs_alt_tag', bm, [mat('opslabs_alt_tag'), mat('opslabs_pwr_galv')]), 40.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.03, -0.006, 0.0, 0.03, 0.0, 0.25, mi=0)
cyl(bm, uv, (0, -0.006, 0.2), (0, -0.2, 0.2), 0.01, sides=6, mi=0)
for k in range(2):
    R = 0.12 - k * 0.01
    n = 18
    pts = [(R * math.sin(2 * math.pi * i / n), -0.2 - k * 0.01, 0.08 + R * math.cos(2 * math.pi * i / n)) for i in range(n + 1)]
    for i in range(n):
        cyl(bm, uv, pts[i], pts[i + 1], 0.005, sides=5, mi=1)
add(finish('opslabs_alt_pia_bracket', bm, [mat('opslabs_pwr_galv'), mat('opslabs_pwr_black')]), 80.0)

# --- OPS Openline extras: triple-sided bracket, J-hook / pigtail bolt
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0, 0.0), (0, 0, 0.08), 0.13, sides=16, mi=0)                       # band round the pole
for k in range(3):
    a = math.radians(-90 + (k - 1) * 90)
    cyl(bm, uv, (0.13 * math.cos(a), 0.13 * math.sin(a), 0.04), (0.32 * math.cos(a), 0.32 * math.sin(a), 0.04), 0.012, sides=6, mi=0)
    box(bm, uv, 0.32 * math.cos(a) - 0.03, 0.32 * math.sin(a) - 0.03, 0.0, 0.32 * math.cos(a) + 0.03, 0.32 * math.sin(a) + 0.03, 0.08, mi=0)
add(finish('opslabs_triple_bracket', bm, [mat('opslabs_pwr_galv')]), 80.0)
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, 0.03, 0), (0, -0.07, 0), 0.008, sides=6, mi=0)
n = 10
pts = [(0.0, -0.07 - 0.025 * math.sin(math.pi * i / n), 0.025 - 0.025 * math.cos(math.pi * i / n) - 0.025) for i in range(n + 1)]
for i in range(n):
    cyl(bm, uv, pts[i], pts[i + 1], 0.007, sides=6, mi=0)
add(finish('opslabs_jhook', bm, [mat('opslabs_pwr_galv')]), 40.0)

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
ytyp.name = 'opslabs_power_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_power.blend'))
