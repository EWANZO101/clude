"""Copper phone line kit (OPS Openline copper network, generic look, no real operator branding):
  copper cable pieces: black dropwire, off-white internal (CW1308-style) and black 50-pair cable
  internal junction box, secondary line jack, aerial copper joint closure on a pole bracket
  rooftop telecom mast on a non-penetrating ballast frame (poles on top of the exchange)
  hand tools: lineman's butt set and tone tracer probe
blender -b --python build_phoneline.py -- <out_dir>
Cable pieces: along +Y from the origin (like the power / fibre pieces).
Wall kit (JB, line jack): origin = the back face on the wall (y = 0), bottom edge at z = 0, front -Y (like opslabs_nte5c).
Pole kit (aerial joint): origin = the pole surface behind it (y = 0), bottom of the bracket at z = 0, front -Y
(like opslabs_pole_splice_box).
Rooftop mast: origin = centre of the ballast frame on the roof surface, mast up +Z (6.0 m, ring head at 5.8 m).
Hand tools: origin = the grip, long axis along +Y.
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
c = Canvas(16, 256, (24, 24, 26)); c.noise(2); save(c, 'opslabs_cu_drop')                 # black dropwire
c = Canvas(16, 256, (226, 224, 216)); c.noise(2); save(c, 'opslabs_cu_internal')          # off-white CW1308
c = Canvas(32, 256, (20, 20, 22))                                                          # 50-pair: glossy sheath
c.rect(9, 0, 14, 256, (62, 62, 66)); c.rect(10, 0, 12, 256, (92, 92, 96))                  # specular streak
for y in range(0, 256, 64):
    c.rect(0, y, 32, y + 1, (36, 36, 38))                                                  # print marks
c.noise(2); save(c, 'opslabs_cu_multipair')
c = Canvas(64, 64, (238, 238, 234)); c.noise(2); save(c, 'opslabs_cu_white')               # white ABS
c = Canvas(64, 64, (196, 198, 196)); c.noise(2); save(c, 'opslabs_cu_greyplastic')
c = Canvas(64, 64, (150, 154, 158)); c.noise(10); save(c, 'opslabs_cu_galv')
c = Canvas(64, 64, (22, 22, 24)); c.noise(3); save(c, 'opslabs_cu_black')
c = Canvas(64, 64, (132, 132, 128)); c.noise(12); save(c, 'opslabs_cu_concrete')
c = Canvas(64, 64, (226, 102, 22)); c.noise(4); save(c, 'opslabs_cu_orange')               # rubberised orange
c = Canvas(64, 64, (236, 196, 24)); c.noise(4); save(c, 'opslabs_cu_yellow')
c = Canvas(64, 64, (196, 30, 28)); c.noise(3); save(c, 'opslabs_cu_red')
c = Canvas(64, 64, (196, 200, 204)); c.noise(6); save(c, 'opslabs_cu_steel')
# line jack faceplate: white plate, soft bevel, BT-style jack opening + screw caps
c = Canvas(128, 128, (240, 240, 236))
c.rect(0, 0, 128, 4, (214, 214, 210)); c.rect(0, 124, 128, 128, (214, 214, 210))
c.rect(0, 0, 4, 128, (222, 222, 218)); c.rect(124, 0, 128, 128, (222, 222, 218))
c.rrect(44, 66, 84, 92, 3, (40, 40, 42))                                                   # jack opening
c.rect(48, 70, 80, 74, (20, 20, 20)); c.rect(58, 88, 70, 92, (70, 70, 72))                 # contacts / latch slot
for x in (16, 112):
    c.circle(x, 64, 5, (220, 220, 216)); c.rect(x - 4, 63, x + 4, 65, (190, 190, 186))     # screw caps
c.noise(2); save(c, 'opslabs_cu_linejack_face')
# butt set keypad (back of the handset): 4 x 3 grey keys on black
c = Canvas(64, 128, (30, 30, 32))
for r in range(4):
    for k in range(3):
        c.rrect(8 + k * 17, 14 + r * 26, 22 + k * 17, 32 + r * 26, 3, (190, 192, 196))
        c.rect(13 + k * 17, 21 + r * 26, 17 + k * 17, 25 + r * 26, (40, 40, 42))
c.rect(8, 118, 56, 122, (226, 102, 22))
save(c, 'opslabs_cu_keypad')

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


def path(bm, uv, pts, r, sides=6, mi=0):
    """a wire along a polyline"""
    for p, q in zip(pts, pts[1:]):
        cyl(bm, uv, p, q, r, sides=sides, mi=mi)


def saddle(bm, uv, z0, z1, w=0.05, mi=1):
    """galvanised mounting plate, slightly curved to sit on the pole (as build_telecom.py)"""
    box(bm, uv, -w / 2, -0.006, z0, w / 2, 0.0, z1, mi=mi)
    for x in (-w / 2, w / 2 - 0.004):
        box(bm, uv, x, -0.004, z0, x + 0.004, 0.006, z1, mi=mi)


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# --- copper cable pieces (run along +Y): black dropwire, off-white internal, black 50-pair
for colour, radius, lod in (('drop', 0.0025, 120.0), ('internal', 0.0022, 60.0), ('multipair', 0.008, 150.0)):
    for cm in (5, 10, 25, 50, 100, 200):
        bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
        cyl(bm, uv, (0, 0, 0), (0, cm / 100, 0), radius, sides=8, mi=0, vrep=cm / 100 * 4)
        add(finish(f'opslabs_copper_{colour}_{cm:03d}', bm, [mat('opslabs_cu_' + colour)]), lod)
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=radius * 1.05)
    for f in bm.faces:
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    add(finish(f'opslabs_copper_{colour}_joint', bm, [mat('opslabs_cu_' + colour)]), lod)

# --- internal junction box: white ABS 100 x 75 x 35 mm, screw-on lid (lid line 10 mm off the
#     front), two lid screws, two cable entry knock-outs underneath. Wall kit: back on the wall.
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.05, -0.025, 0.0, 0.05, 0.0, 0.075, mi=0)                              # base
box(bm, uv, -0.0485, -0.0262, 0.0015, 0.0485, -0.025, 0.0735, mi=1)                  # lid line (shadow gap)
box(bm, uv, -0.05, -0.035, 0.0, 0.05, -0.0262, 0.075, mi=0)                          # lid
for x in (-0.036, 0.036):
    cyl(bm, uv, (x, -0.035, 0.0375), (x, -0.0365, 0.0375), 0.0035, sides=10, mi=1)   # lid screws
    cyl(bm, uv, (x, -0.0365, 0.0375), (x, -0.0368, 0.0375), 0.0012, sides=4, mi=2)   # screw slot
for x in (-0.028, 0.028):
    cyl(bm, uv, (x, -0.0125, 0.0), (x, -0.0125, -0.0012), 0.0065, sides=12, mi=1)    # knock-outs
add(finish('opslabs_copper_jb', bm, [mat('opslabs_cu_white'), mat('opslabs_cu_greyplastic'), mat('opslabs_cu_black')]), 25.0, 'PLASTIC')

# --- secondary line jack: single-gang surface box + 86 x 86 faceplate with the jack opening
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.042, -0.016, 0.001, 0.042, 0.0, 0.085, mi=0)                          # pattress box
box(bm, uv, -0.043, -0.024, 0.0, 0.043, -0.016, 0.086, mi=0, front=1)                # faceplate
box(bm, uv, -0.0095, -0.0242, 0.0195, 0.0095, -0.024, 0.0305, mi=2)                   # jack mouth (raised rim)
add(finish('opslabs_copper_linejack', bm, [mat('opslabs_cu_white'), mat('opslabs_cu_linejack_face'), mat('opslabs_cu_black')]), 25.0, 'PLASTIC')

# --- aerial copper joint closure: black ribbed sleeve 0.45 m x Ø 90 standing off the pole on a
#     galvanised bracket (two arms with clamp bands), cable glands at the bottom. Pole kit.
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
saddle(bm, uv, 0.0, 0.55, w=0.06, mi=1)
cy_ = -0.115
for z in (0.12, 0.43):
    box(bm, uv, -0.02, -0.068, z - 0.012, 0.02, -0.006, z + 0.012, mi=1)              # stand-off arm
    n = 16
    for k in range(n):                                                                # clamp band
        a0, a1 = 2 * math.pi * k / n, 2 * math.pi * (k + 1) / n
        cyl(bm, uv, (0.05 * math.cos(a0), cy_ + 0.05 * math.sin(a0), z), (0.05 * math.cos(a1), cy_ + 0.05 * math.sin(a1), z), 0.004, sides=5, mi=1)
    cyl(bm, uv, (0.0, -0.064, z), (0.0, -0.072, z), 0.008, sides=6, mi=1)            # band bolt
cyl(bm, uv, (0, cy_, 0.07), (0, cy_, 0.48), 0.045, sides=20, mi=0, vrep=2)            # sleeve
for k in range(13):                                                                   # ribs
    z = 0.09 + k * 0.03
    cyl(bm, uv, (0, cy_, z), (0, cy_, z + 0.007), 0.048, sides=20, mi=0)
cyl(bm, uv, (0, cy_, 0.48), (0, cy_, 0.50), 0.045, 0.03, sides=20, mi=0)              # top end cap
cyl(bm, uv, (0, cy_, 0.07), (0, cy_, 0.05), 0.045, 0.034, sides=20, mi=0)             # bottom end cap
for x in (-0.016, 0.016):
    cyl(bm, uv, (x, cy_, 0.05), (x, cy_, 0.02), 0.009, 0.007, sides=8, mi=0)          # cable glands
    cyl(bm, uv, (x, cy_, 0.02), (x, cy_, -0.06), 0.004, sides=6, mi=0)                # cable tails
add(finish('opslabs_copper_joint_aerial', bm, [mat('opslabs_cu_black'), mat('opslabs_cu_galv')]), 100.0, 'PLASTIC')

# --- rooftop telecom mast: non-penetrating ballast frame 1.6 x 1.6 m (C-channel, 80 mm high)
#     with a ballast tray + concrete block (400 x 400 x 100) on each corner, corner posts and four
#     diagonal braces to 1.2 m up a 6.0 m galvanised tubular mast (r 0.09 -> 0.065), ring head at
#     5.8 m, step bolts every 0.4 m from 0.6 m to 5.4 m. Origin = frame centre on the roof.
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
H, RB, RT, FH, FW, T = 6.0, 0.09, 0.065, 0.08, 0.06, 0.008


def mast_r(z):
    return RB + (RT - RB) * z / H


for s in (-1, 1):                                                                     # perimeter C-channels (open side in)
    y0, y1 = (0.8 - T, 0.8) if s > 0 else (-0.8, -0.8 + T)
    box(bm, uv, -0.8, y0, 0.0, 0.8, y1, FH, mi=0)                                       # web
    fy0, fy1 = (0.8 - FW, 0.8) if s > 0 else (-0.8, -0.8 + FW)
    box(bm, uv, -0.8, fy0, 0.0, 0.8, fy1, T, mi=0)                                      # flanges
    box(bm, uv, -0.8, fy0, FH - T, 0.8, fy1, FH, mi=0)
    x0, x1 = (0.8 - T, 0.8) if s > 0 else (-0.8, -0.8 + T)
    box(bm, uv, x0, -0.8 + FW, 0.0, x1, 0.8 - FW, FH, mi=0)
    fx0, fx1 = (0.8 - FW, 0.8) if s > 0 else (-0.8, -0.8 + FW)
    box(bm, uv, fx0, -0.8 + FW, 0.0, fx1, 0.8 - FW, T, mi=0)
    box(bm, uv, fx0, -0.8 + FW, FH - T, fx1, 0.8 - FW, FH, mi=0)
box(bm, uv, -0.8 + FW, -0.03, 0.0, 0.8 - FW, 0.03, FH, mi=0)                          # centre cross members
box(bm, uv, -0.03, -0.8 + FW, 0.0, 0.03, -0.03, FH, mi=0)
box(bm, uv, -0.03, 0.03, 0.0, 0.03, 0.8 - FW, FH, mi=0)
for sx in (-1, 1):
    for sy in (-1, 1):
        cx, cy = sx * 0.58, sy * 0.58
        box(bm, uv, min(sx * 0.37, sx * 0.8), min(sy * 0.37, sy * 0.8), FH - T, max(sx * 0.37, sx * 0.8), max(sy * 0.37, sy * 0.8), FH, mi=0)  # ballast tray
        box(bm, uv, cx - 0.2, cy - 0.2, FH, cx + 0.2, cy + 0.2, FH + 0.1, mi=1)        # concrete ballast block
        px, py = sx * 0.78, sy * 0.78
        box(bm, uv, px - 0.02, py - 0.02, FH, px + 0.02, py + 0.02, 0.27, mi=0)        # corner post
        top = mathutils.Vector((sx * 0.78, sy * 0.78, 0.25))
        a = math.atan2(sy, sx)
        rr = mast_r(1.2)
        cyl(bm, uv, tuple(top), (rr * math.cos(a), rr * math.sin(a), 1.2), 0.022, sides=8, mi=0)   # diagonal brace
        cyl(bm, uv, ((rr + 0.01) * math.cos(a), (rr + 0.01) * math.sin(a), 1.17), ((rr + 0.01) * math.cos(a), (rr + 0.01) * math.sin(a), 1.25), 0.02, sides=6, mi=0)  # brace lug
box(bm, uv, -0.2, -0.2, FH, 0.2, 0.2, FH + 0.02, mi=0)                                # mast base plate
for k in range(4):                                                                    # base gussets
    a = math.pi / 4 + k * math.pi / 2
    cyl(bm, uv, (0.17 * math.cos(a), 0.17 * math.sin(a), FH + 0.02), (0.085 * math.cos(a), 0.085 * math.sin(a), FH + 0.2), 0.012, sides=6, mi=0)
cyl(bm, uv, (0, 0, FH + 0.02), (0, 0, H), mast_r(FH + 0.02), RT, sides=16, mi=0, vrep=4)   # mast
cyl(bm, uv, (0, 0, H), (0, 0, H + 0.02), RT, 0.03, sides=16, mi=0)                    # cap
cyl(bm, uv, (0, 0, 5.77), (0, 0, 5.83), mast_r(5.8) + 0.011, sides=16, mi=0, vrep=0.2)   # ring head
cyl(bm, uv, (0, 0, 1.17), (0, 0, 1.25), mast_r(1.2) + 0.006, sides=16, mi=0)        # brace collar
z = 0.6
k = 0
while z <= 5.4 + 1e-6:
    s = 1 if k % 2 else -1
    r = mast_r(z)
    cyl(bm, uv, (s * (r - 0.03), 0, z), (s * (r + 0.14), 0, z), 0.009, sides=6, mi=0)  # step bolt
    cyl(bm, uv, (s * (r + 0.13), 0, z), (s * (r + 0.13), 0, z + 0.04), 0.009, sides=6, mi=0)  # upturned end
    z = round(z + 0.4, 3); k += 1
add(finish('opslabs_pole_roof', bm, [mat('opslabs_cu_galv'), mat('opslabs_cu_concrete')]), 300.0, 'METAL_SOLID_MEDIUM')

# --- lineman's butt set: orange rubberised handset 0.23 m along +Y (origin = the grip, the middle
#     of the handle), ear and mouth cups on the front (+Z), keypad on the back (-Z), coiled lead
#     out of the bottom end with red / black crocodile clips dangling ~0.15 m below.
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
box(bm, uv, -0.025, -0.06, -0.016, 0.025, 0.06, 0.016, mi=0)                          # handle
box(bm, uv, -0.03, 0.06, -0.022, 0.03, 0.12, 0.024, mi=0)                             # ear end
box(bm, uv, -0.03, -0.115, -0.022, 0.03, -0.06, 0.024, mi=0)                          # mouth end
cyl(bm, uv, (0, 0.09, 0.024), (0, 0.09, 0.034), 0.027, 0.024, sides=16, mi=1)         # ear cup
cyl(bm, uv, (0, -0.088, 0.024), (0, -0.088, 0.032), 0.025, 0.022, sides=16, mi=1)     # mouth cup
box(bm, uv, -0.021, -0.05, -0.0165, 0.021, 0.05, -0.016, mi=2)                        # keypad (back)
box(bm, uv, -0.008, 0.10, 0.024, 0.008, 0.115, 0.03, mi=1)                            # talk / monitor switch
cyl(bm, uv, (0, -0.115, 0.0), (0, -0.125, 0.0), 0.007, sides=8, mi=1)                 # strain relief
pts = []
for i in range(121):                                                                  # coiled lead, hanging down
    t = i / 120
    a = t * 2 * math.pi * 12
    pts.append((0.006 * math.cos(a), -0.13 + 0.006 * math.sin(a), -0.012 - t * 0.10))
pts.insert(0, (0, -0.125, 0.0))
path(bm, uv, pts, 0.0016, sides=5, mi=1)
for sx, mi in ((-1, 3), (1, 1)):                                                      # split to two clips
    p0 = pts[-1]
    p1 = (sx * 0.012, -0.13, -0.125)
    path(bm, uv, [p0, p1], 0.0012, sides=5, mi=mi)
    cx, cy, cz = p1
    box(bm, uv, cx - 0.004, cy - 0.003, cz - 0.022, cx + 0.004, cy + 0.003, cz, mi=mi)   # insulating boot
    box(bm, uv, cx - 0.003, cy - 0.0025, cz - 0.045, cx + 0.003, cy - 0.0002, cz - 0.022, mi=4)   # jaws
    box(bm, uv, cx - 0.003, cy + 0.0002, cz - 0.045, cx + 0.003, cy + 0.0025, cz - 0.022, mi=4)
add(finish('opslabs_tool_buttset', bm, [mat('opslabs_cu_orange'), mat('opslabs_cu_black'), mat('opslabs_cu_keypad'), mat('opslabs_cu_red'), mat('opslabs_cu_steel')]), 30.0)

# --- tone tracer probe: slim yellow / black pen-shaped probe 0.21 m along +Y, metal tip at +Y,
#     black rubber grip band round the origin
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
cyl(bm, uv, (0, -0.09, 0), (0, -0.08, 0), 0.010, 0.012, sides=14, mi=1)               # end cap
cyl(bm, uv, (0, -0.08, 0), (0, 0.06, 0), 0.012, sides=14, mi=0)                       # yellow body
cyl(bm, uv, (0, -0.03, 0), (0, 0.03, 0), 0.0128, sides=14, mi=1)                      # grip band
for y in (-0.02, -0.01, 0.0, 0.01, 0.02):
    cyl(bm, uv, (0, y, 0), (0, y + 0.004, 0), 0.0134, sides=14, mi=1)                 # grip ribs
cyl(bm, uv, (0, 0.06, 0), (0, 0.10, 0), 0.012, 0.005, sides=14, mi=1)                 # black nose
cyl(bm, uv, (0, 0.10, 0), (0, 0.12, 0), 0.0016, 0.0006, sides=8, mi=2)                # metal tip
box(bm, uv, -0.004, 0.035, 0.0115, 0.004, 0.05, 0.0145, mi=1)                         # push button
cyl(bm, uv, (0, -0.055, 0.0115), (0, -0.055, 0.0135), 0.0025, sides=8, mi=3)          # LED
add(finish('opslabs_tool_toner', bm, [mat('opslabs_cu_yellow'), mat('opslabs_cu_black'), mat('opslabs_cu_steel'), mat('opslabs_cu_red')]), 30.0)

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
ytyp.name = 'opslabs_phoneline_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_phoneline.blend'))
