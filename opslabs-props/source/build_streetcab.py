"""UK-style green street telecom cabinet (3-door, generic, no operator branding) + red Chapter 8
interlocking pedestrian barrier.
  opslabs_cabinet_green3        cabinet, doors closed
  opslabs_cabinet_green3_open   same, middle door swung open ~100 deg to the right, interior visible
  opslabs_rw_barrier_red        1.0 m x 1.0 m red plastic barrier, length along X (x -0.5 .. +0.5)
blender -b --python build_streetcab.py -- <out_dir>
Origins: ground level (z = 0), centre of the footprint, fronts face -Y.
Cabinet: body 1.25 W x 0.55 D, 1.30 to the eaves on a 0.08 plinth, lid 1.33 x 0.63 overhang, ridge 1.42.
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


GREEN = (44, 66, 48)
GREEN_D = (24, 36, 27)
# ---------------------------------------------------------------- textures
c = Canvas(128, 128, GREEN)                                                   # weathered BT green steel
c.vgrad(0, 0, 128, 128, (50, 73, 54), (40, 60, 44))
for x in (9, 31, 58, 77, 101, 119):
    c.rect(x, 20 + x % 30, x + 2, 128, (36, 54, 40), 0.35)                    # faint run-off streaks
c.noise(4); save(c, 'opslabs_sc_green')
c = Canvas(64, 64, (36, 56, 41)); c.noise(3); save(c, 'opslabs_sc_green_d')  # lid / shadowed panels
c = Canvas(64, 64, (34, 34, 36)); c.noise(4); save(c, 'opslabs_sc_plinth')
c = Canvas(64, 64, (14, 16, 15)); c.noise(2); save(c, 'opslabs_sc_dark')     # gaps / recesses / interior back
c = Canvas(64, 64, (168, 172, 176)); c.noise(6); save(c, 'opslabs_sc_steel')
c = Canvas(64, 64, (120, 124, 128)); c.noise(5); save(c, 'opslabs_sc_grey')
# louvre vent: rows of dark horizontal slots on green
for name, cols, rows in (('opslabs_sc_vent', 6, 4), ('opslabs_sc_vent_s', 2, 3), ('opslabs_sc_vent_side', 3, 8)):
    c = Canvas(128, 128, GREEN)
    cw, rh = 128 / cols, 128 / rows
    for i in range(cols):
        for j in range(rows):
            x0, y0 = i * cw + cw * 0.15, j * rh + rh * 0.3
            c.rrect(x0, y0, x0 + cw * 0.7, y0 + rh * 0.4, 2, (10, 12, 11))
            c.rect(x0, y0 + rh * 0.4, x0 + cw * 0.7, y0 + rh * 0.48, (70, 96, 74))   # lit lower lip
    c.noise(3); save(c, name)
# ID label: white with black text lines + barcode-ish stripes
c = Canvas(64, 32, (236, 236, 230))
c.rect(4, 4, 44, 8, (20, 20, 20)); c.rect(4, 12, 34, 15, (40, 40, 40)); c.rect(4, 19, 38, 22, (40, 40, 40))
for x in range(48, 60, 2):
    c.rect(x, 4, x + 1, 28, (20, 20, 20))
c.noise(2); save(c, 'opslabs_sc_label')
# patch panel: grey strip with rows of black ports and a few coloured patch leads
c = Canvas(256, 32, (150, 154, 158))
for k in range(24):
    x = 8 + k * 10
    c.rect(x, 9, x + 7, 15, (16, 16, 18)); c.rect(x, 18, x + 7, 24, (16, 16, 18))
for k, col in ((2, (40, 120, 220)), (5, (230, 210, 40)), (9, (40, 120, 220)), (14, (220, 60, 40)), (17, (40, 180, 80))):
    c.rect(8 + k * 10, 9, 15 + k * 10, 15, col)
c.noise(3); save(c, 'opslabs_sc_patch')
# DSLAM / line card shelf front: dark grey with vertical cards and green LEDs
c = Canvas(256, 64, (60, 62, 66))
for k in range(16):
    x = 4 + k * 15.6
    c.rect(x, 4, x + 13, 60, (84, 86, 90)); c.rect(x + 2, 8, x + 5, 11, (60, 230, 90)); c.rect(x + 2, 50, x + 11, 56, (30, 30, 32))
c.noise(3); save(c, 'opslabs_sc_shelf')
c = Canvas(32, 32, (30, 30, 32)); c.noise(2); save(c, 'opslabs_sc_cable_k')
c = Canvas(32, 32, (220, 220, 214)); c.noise(2); save(c, 'opslabs_sc_cable_w')
c = Canvas(32, 32, (40, 110, 210)); c.noise(2); save(c, 'opslabs_sc_cable_b')
# barrier
c = Canvas(64, 64, (214, 28, 30)); c.noise(4); save(c, 'opslabs_sc_red')
c = Canvas(64, 64, (244, 244, 240)); c.noise(2); save(c, 'opslabs_sc_white')
c = Canvas(64, 64, (22, 22, 24)); c.noise(3); save(c, 'opslabs_sc_rubber')
c = Canvas(64, 64, (250, 206, 24)); c.noise(3); save(c, 'opslabs_sc_yellow')

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


def box(bm, uv, x0, y0, z0, x1, y1, z1, mi=0, front=None, back=None, skip=(), inward=False):
    F = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    over = {'front': front, 'back': back}
    uvs = ((0, 0), (1, 0), (1, 1), (0, 1))
    for k, vs in F.items():
        if k in skip:
            continue
        if inward:
            vs = list(reversed(vs))
            q = list(reversed(uvs))
        else:
            q = uvs
        f = bm.faces.new([bm.verts.new(v) for v in vs])
        f.material_index = over[k] if over.get(k) is not None else mi
        for loop, u in zip(f.loops, q):
            loop[uv].uv = u


def cyl(bm, uv, p0, p1, r0, r1=None, sides=12, mi=0, vrep=1.0, caps=True):
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
    if caps:
        for k, ring in enumerate(rings):
            f = bm.faces.new(ring if k else list(reversed(ring)))
            f.material_index = mi
            for loop in f.loops:
                loop[uv].uv = (0.5, 0.5)


def path(bm, uv, pts, r, sides=6, mi=0):
    for p, q in zip(pts, pts[1:]):
        cyl(bm, uv, p, q, r, sides=sides, mi=mi)


def xform_from(bm, n0, M):
    bm.verts.ensure_lookup_table()
    for v in bm.verts[n0:]:
        v.co = M @ v.co


models = []


def add(obj, lod, colmat=None):
    models.append((obj, lod, colmat))


# ---------------------------------------------------------------- cabinet
W2, D2 = 0.625, 0.275            # half width / depth of the body
ZP, ZE = 0.08, 1.30              # plinth top / eaves (body top)
OV = 0.04                        # lid overhang
DZ0, DZ1 = 0.12, 1.26            # door bottom / top
DOORS = ((-0.612, -0.112), (-0.104, 0.206), (0.214, 0.612))   # left wide, middle narrow, right
DT = 0.012                       # door thickness proud of the body front
YF = -D2                         # body front plane
CAB_MATS = ['opslabs_sc_green', 'opslabs_sc_green_d', 'opslabs_sc_plinth', 'opslabs_sc_dark', 'opslabs_sc_steel',
            'opslabs_sc_vent', 'opslabs_sc_vent_s', 'opslabs_sc_vent_side', 'opslabs_sc_label', 'opslabs_sc_grey',
            'opslabs_sc_patch', 'opslabs_sc_shelf', 'opslabs_sc_cable_k', 'opslabs_sc_cable_w', 'opslabs_sc_cable_b']
MI = {n.replace('opslabs_sc_', ''): i for i, n in enumerate(CAB_MATS)}


def door(bm, uv, x0, x1, kind):
    """door panel in closed position (front face at y = YF - DT)"""
    y0 = YF - DT
    box(bm, uv, x0, y0, DZ0, x1, YF, DZ1, mi=MI['green'])
    box(bm, uv, x0 + 0.02, y0 - 0.003, DZ0 + 0.02, x1 - 0.02, y0, DZ0 + 0.025, mi=MI['green_d'])   # pressed rib bottom
    box(bm, uv, x0 + 0.02, y0 - 0.003, DZ1 - 0.025, x1 - 0.02, y0, DZ1 - 0.02, mi=MI['green_d'])   # pressed rib top
    if kind == 'left':
        cx = (x0 + x1) / 2 - 0.02
        box(bm, uv, cx - 0.12, y0 - 0.002, 0.86, cx + 0.12, y0, 1.02, mi=MI['vent'])               # louvre panel
        lx, hz = x1 - 0.05, 0.80
    elif kind == 'mid':
        cx = (x0 + x1) / 2
        box(bm, uv, cx - 0.04, y0 - 0.002, 0.92, cx + 0.04, y0, 1.02, mi=MI['vent_s'])             # small vent
        box(bm, uv, x0 + 0.05, y0 - 0.002, 1.12, x0 + 0.14, y0, 1.17, mi=MI['label'])              # ID label
        lx, hz = x0 + 0.05, 0.86
        box(bm, uv, lx - 0.012, y0 - 0.004, 0.64, lx + 0.012, y0, 0.70, mi=MI['dark'])             # lower lock
        cyl(bm, uv, (lx, y0, 0.67), (lx, y0 - 0.008, 0.67), 0.008, sides=10, mi=MI['steel'])
    else:
        lx, hz = x0 + 0.05, 0.80
    # recessed handle pocket + chrome lock barrel
    box(bm, uv, lx - 0.018, y0 - 0.002, hz - 0.06, lx + 0.018, y0, hz + 0.06, mi=MI['dark'])
    box(bm, uv, lx - 0.006, y0 - 0.01, hz - 0.045, lx + 0.006, y0 - 0.002, hz + 0.02, mi=MI['steel'])
    cyl(bm, uv, (lx, y0, hz + 0.09), (lx, y0 - 0.008, hz + 0.09), 0.009, sides=10, mi=MI['steel'])
    cyl(bm, uv, (lx, y0 - 0.008, hz + 0.09), (lx, y0 - 0.0085, hz + 0.09), 0.004, sides=6, mi=MI['dark'])


def cabinet(name, open_mid):
    bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
    box(bm, uv, -W2 + 0.03, -D2 + 0.03, 0.0, W2 - 0.03, D2 - 0.03, ZP, mi=MI['plinth'])          # plinth
    box(bm, uv, -W2, -D2, ZP, W2, D2, ZE, mi=MI['green'], skip=('front',))                       # body shell
    ox0, ox1 = DOORS[1][0] - 0.004, DOORS[1][1] + 0.004                                            # middle door opening
    for (a, b) in ((-W2, ox0), (ox1, W2)):                                                         # front face around it
        box(bm, uv, a, YF, ZP, b, YF + 0.015, ZE, mi=MI['dark'], skip=('back',))
    box(bm, uv, ox0, YF, ZP, ox1, YF + 0.015, DZ0 - 0.004, mi=MI['green'], skip=('back',))
    box(bm, uv, ox0, YF, DZ1 + 0.004, ox1, YF + 0.015, ZE, mi=MI['green'], skip=('back',))
    box(bm, uv, -W2 + 0.015, -D2 + 0.015, ZP + 0.01, W2 - 0.015, D2 - 0.01, ZE - 0.01, mi=MI['dark'], inward=True, skip=('front',))  # interior liner
    for (a, b) in ((-W2, DOORS[0][0]), (DOORS[2][1], W2)):
        box(bm, uv, a, YF - 0.004, ZP, b, YF, ZE, mi=MI['green'])
    # door frame band (green) between doors and edges
    box(bm, uv, -W2, YF - 0.004, DZ0 - 0.04, W2, YF, DZ0 - 0.004, mi=MI['green'])
    box(bm, uv, -W2, YF - 0.004, DZ1 + 0.004, W2, YF, ZE, mi=MI['green'])
    for k, (x0, x1) in enumerate(DOORS):
        kind = ('left', 'mid', 'right')[k]
        if kind == 'mid' and open_mid:
            n0 = len(bm.verts)
            door(bm, uv, x0, x1, kind)
            box(bm, uv, x0 + 0.01, YF, DZ0 + 0.01, x1 - 0.01, YF + 0.02, DZ1 - 0.01, mi=MI['grey'])    # inner door skin
            hx, hy = x1 + 0.002, YF - DT
            M = (mathutils.Matrix.Translation((hx, hy, 0)) @ mathutils.Matrix.Rotation(math.radians(100), 4, 'Z')
                 @ mathutils.Matrix.Translation((-hx, -hy, 0)))
            xform_from(bm, n0, M)
        else:
            door(bm, uv, x0, x1, kind)
    for z0, z1 in ((DZ0 + 0.06, DZ0 + 0.2), (DZ1 - 0.2, DZ1 - 0.06)):                             # hinges on middle door's right edge
        hx = DOORS[1][1] + 0.004
        cyl(bm, uv, (hx, YF - DT, z0), (hx, YF - DT, z0 + 0.05), 0.006, sides=8, mi=MI['dark'])
    # side vents (both ends) near the top
    for s in (-1, 1):
        x = s * W2
        box(bm, uv, min(x, x + s * 0.002), -0.12, 0.92, max(x, x + s * 0.002), 0.12, 1.14, mi=MI['vent_side'])
    # lid: overhanging eaves slab + shallow ridge (ridge along Y, slopes to +/-X)
    LX, LY = W2 + OV, D2 + OV
    box(bm, uv, -LX, -LY, ZE, LX, LY, ZE + 0.035, mi=MI['green_d'])
    zr = ZE + 0.035 + 0.085
    v = {}
    for y in (-LY, LY):
        v[(y, 'l')] = bm.verts.new((-LX, y, ZE + 0.035))
        v[(y, 'r')] = bm.verts.new((LX, y, ZE + 0.035))
        v[(y, 'c')] = bm.verts.new((0, y, zr))
    faces = [
        ([v[(-LY, 'l')], v[(-LY, 'c')], v[(LY, 'c')], v[(LY, 'l')]], 'green'),   # left slope
        ([v[(-LY, 'r')], v[(LY, 'r')], v[(LY, 'c')], v[(-LY, 'c')]], 'green'),    # right slope
        ([v[(-LY, 'l')], v[(-LY, 'r')], v[(-LY, 'c')]], 'green_d'),                     # front gable
        ([v[(LY, 'r')], v[(LY, 'l')], v[(LY, 'c')]], 'green_d'),                        # back gable
    ]
    for vs, m in faces:
        f = bm.faces.new(vs)
        f.material_index = MI[m]
        for loop in f.loops:
            co = loop.vert.co
            loop[uv].uv = (co.x + 0.5, co.y + co.z)
    bm.normal_update()
    if open_mid:
        # interior equipment behind the middle door: rack rails, line-card shelf, patch panels, cables
        ix0, ix1 = DOORS[1][0] - 0.10, DOORS[1][1] + 0.10
        for x in (ix0, ix1 - 0.02):
            box(bm, uv, x, -0.20, 0.15, x + 0.02, -0.18, 1.24, mi=MI['grey'])                    # rack uprights
        box(bm, uv, ix0, -0.19, 0.95, ix1, 0.20, 1.18, mi=MI['grey'], front=MI['shelf'])         # line-card shelf
        for k, z in enumerate((0.84, 0.76, 0.68, 0.60)):
            box(bm, uv, ix0, -0.19, z, ix1, 0.10, z + 0.06, mi=MI['grey'], front=MI['patch'])    # patch panels
        box(bm, uv, ix0, -0.19, 0.30, ix1, 0.22, 0.34, mi=MI['grey'])                            # cable tray shelf
        box(bm, uv, ix0 + 0.03, -0.12, 0.34, ix1 - 0.03, 0.20, 0.52, mi=MI['dark'], front=MI['shelf'])   # PSU / battery unit
        import random
        rnd = random.Random(4)
        for k in range(9):                                                                       # patch leads / tie cables
            x = ix0 + 0.04 + k * (ix1 - ix0 - 0.08) / 8
            z = 0.62 + (k % 4) * 0.08
            m = (MI['cable_b'], MI['cable_w'], MI['cable_k'])[k % 3]
            path(bm, uv, [(x, -0.195, z + 0.03), (x + rnd.uniform(-0.02, 0.02), -0.215, z - 0.02),
                          (x * 0.6 + ix1 * 0.4 * (k % 2), -0.21, 0.38), (x * 0.5, -0.05, 0.12)], 0.004, sides=5, mi=m)
        for x in (ix0 + 0.06, ix1 - 0.06):                                                        # thick feeder cables from the plinth
            path(bm, uv, [(x, 0.15, 0.09), (x, 0.12, 0.30), (x, 0.10, 0.95)], 0.012, sides=8, mi=MI['cable_k'])
    add(finish(name, bm, [mat(n) for n in CAB_MATS]), 120.0, 'METAL_SOLID_MEDIUM')


cabinet('opslabs_cabinet_green3', False)
cabinet('opslabs_cabinet_green3_open', True)

# ---------------------------------------------------------------- Chapter 8 barrier 1.0 x 1.0
bm = bmesh.new(); uv = bm.loops.layers.uv.new('UVMap 0')
R, W, Y, B, K = 0, 1, 2, 3, 4    # red, white, yellow, rubber, (unused)
PX = 0.475                       # end post centre (outer edge at x = 0.5)
PR = 0.025
TZ = 0.965                       # top rail centre
cyl(bm, uv, (-PX + 0.06, 0, TZ), (PX - 0.06, 0, TZ), 0.03, sides=12, mi=R)                     # rounded top rail
for s in (-1, 1):
    pts = [(s * (PX - 0.06 + 0.06 * math.sin(a)), 0, TZ - 0.06 + 0.06 * math.cos(a)) for a in [i * math.pi / 8 for i in range(5)]]
    path(bm, uv, pts, 0.028, sides=10, mi=R)                                                    # rounded corners
    cyl(bm, uv, (s * PX, 0, 0.06), (s * PX, 0, TZ - 0.06), PR, sides=10, mi=R)                  # end posts
    # black rubber foot / ballast block under each end, spreading front/back
    fx = s * 0.40
    box(bm, uv, fx - 0.06, -0.24, 0.0, fx + 0.06, 0.24, 0.05, mi=B)
    box(bm, uv, fx - 0.045, -0.20, 0.05, fx + 0.045, 0.20, 0.075, mi=B)
    box(bm, uv, fx - 0.03, -0.03, 0.05, fx + 0.03, 0.03, 0.16, mi=R)                            # leg socket
# panel body: bottom rail, mid rails, vertical bars -> grid of openings
T = 0.018
box(bm, uv, -PX, -T, 0.12, PX, T, 0.17, mi=R)                                                   # bottom rail
for z in (0.40, 0.62):
    box(bm, uv, -PX, -T, z, PX, T, z + 0.04, mi=R)                                              # mid rails
box(bm, uv, -PX, -T, 0.88, PX, T, 0.92, mi=R)                                                   # upper rail
for x in (-0.315, -0.155, 0.0, 0.155, 0.315):
    box(bm, uv, x - 0.016, -T * 0.8, 0.17, x + 0.016, T * 0.8, 0.62, mi=R)                     # lower verticals
# upper band: solid red panel with white reflective plate (both sides), side openings
box(bm, uv, -0.24, -T * 0.6, 0.66, 0.24, T * 0.6, 0.88, mi=R)
for x in (-0.36, 0.36):
    box(bm, uv, x - 0.016, -T * 0.8, 0.66, x + 0.016, T * 0.8, 0.88, mi=R)
box(bm, uv, -0.17, -T * 0.6 - 0.002, 0.68, 0.17, T * 0.6 + 0.002, 0.86, mi=W)
# interlocking: pegs on +X end, hooks on -X end, yellow clip on +X
for z in (0.30, 0.75):
    cyl(bm, uv, (PX + PR - 0.004, 0, z), (0.52, 0, z), 0.012, sides=8, mi=R)                   # peg
    cyl(bm, uv, (0.52, 0, z), (0.52, 0, z - 0.05), 0.010, sides=8, mi=R)                       # down-turned pin
    box(bm, uv, -PX - PR - 0.012, -0.02, z - 0.08, -PX - PR + 0.004, 0.02, z - 0.03, mi=R)     # receiving hook
box(bm, uv, PX - 0.018, -0.03, 0.50, 0.505, 0.03, 0.56, mi=Y)                                  # yellow clip
box(bm, uv, 0.49, -0.03, 0.47, 0.51, 0.03, 0.59, mi=Y)
add(finish('opslabs_rw_barrier_red', bm, [mat('opslabs_sc_red'), mat('opslabs_sc_white'), mat('opslabs_sc_yellow'), mat('opslabs_sc_rubber')]), 100.0, 'PLASTIC')

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
bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_streetcab_props'
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
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_streetcab.blend'))
