"""UniFi-style gateways: UDM Pro (1U rack) + Cloud Gateway Ultra (desktop).
Exports CodeWalker XML with Sollumz:  blender -b --python build_gateways.py -- <out_dir>
Fronts face -Y so a freshly placed prop faces the player. Origin: bottom centre.
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


def col_index(name):
    return next((i for i, m in enumerate(sz_col.collisionmats) if m.name == name), 0)


# ---------------------------------------------------------------------------
# tiny raster canvas -> DDS (A8R8G8B8 with mips)
# ---------------------------------------------------------------------------

class Canvas:
    def __init__(self, w, h, color):
        self.w, self.h = w, h
        self.px = [list(color) + ([255] if len(color) == 3 else []) for _ in range(w * h)]

    def _put(self, x, y, c, a=1.0):
        if 0 <= x < self.w and 0 <= y < self.h:
            p = self.px[y * self.w + x]
            for i in range(3):
                p[i] = int(p[i] * (1 - a) + c[i] * a)

    def rect(self, x0, y0, x1, y1, c, a=1.0):
        for y in range(max(0, int(y0)), min(self.h, int(y1))):
            for x in range(max(0, int(x0)), min(self.w, int(x1))):
                self._put(x, y, c, a)

    def rrect(self, x0, y0, x1, y1, r, c, a=1.0):
        for y in range(max(0, int(y0)), min(self.h, int(y1))):
            for x in range(max(0, int(x0)), min(self.w, int(x1))):
                cx = min(max(x + 0.5, x0 + r), x1 - r)
                cy = min(max(y + 0.5, y0 + r), y1 - r)
                d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
                if d <= r:
                    self._put(x, y, c, a * min(1.0, r - d + 0.5))

    def circle(self, cx, cy, r, c, a=1.0):
        self.rrect(cx - r, cy - r, cx + r, cy + r, r, c, a)

    def vgrad(self, x0, y0, x1, y1, c0, c1):
        for y in range(max(0, int(y0)), min(self.h, int(y1))):
            t = (y - y0) / max(1, (y1 - y0 - 1))
            c = [int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)]
            self.rect(x0, y, x1, y + 1, c)

    def noise(self, amount, seed=7):
        s = seed
        for p in self.px:
            s = (s * 1103515245 + 12345) & 0x7fffffff
            n = ((s >> 16) % (amount * 2 + 1)) - amount
            for i in range(3):
                p[i] = max(0, min(255, p[i] + n))

    def brushed(self, amount):
        # horizontal streaks like brushed aluminium
        s = 3
        for y in range(self.h):
            s = (s * 1103515245 + 12345) & 0x7fffffff
            n = ((s >> 16) % (amount * 2 + 1)) - amount
            for x in range(self.w):
                p = self.px[y * self.w + x]
                for i in range(3):
                    p[i] = max(0, min(255, p[i] + n))

    def save_dds(self, path):
        levels = [(self.w, self.h, self.px)]
        while levels[-1][0] > 1 or levels[-1][1] > 1:
            w, h, px = levels[-1]
            nw, nh = max(1, w // 2), max(1, h // 2)
            out = []
            for y in range(nh):
                for x in range(nw):
                    acc = [0, 0, 0, 0]
                    n = 0
                    for dy in (0, 1):
                        for dx in (0, 1):
                            sx, sy = min(w - 1, x * 2 + dx), min(h - 1, y * 2 + dy)
                            q = px[sy * w + sx]
                            for i in range(4):
                                acc[i] += q[i]
                            n += 1
                    out.append([v // n for v in acc])
            levels.append((nw, nh, out))
        data = bytearray()
        for w, h, px in levels:
            for r, g, b, a in px:
                data += bytes((b, g, r, a))
        flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x8 | 0x20000
        header = struct.pack('<4sIIIIIII44x', b'DDS ', 124, flags, self.h, self.w, self.w * 4, 0, len(levels))
        pf = struct.pack('<II4sIIIII', 32, 0x41, b'\0\0\0\0', 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
        caps = struct.pack('<IIII4x', 0x1000 | 0x8 | 0x400000, 0, 0, 0)
        with open(path, 'wb') as f:
            f.write(header + pf + caps + data)


def rj45(c, x, y, w, h, lit=True, led=(60, 220, 90)):
    c.rrect(x, y, x + w, y + h, 2, (22, 22, 24))           # port body
    c.rect(x + w * 0.18, y + h * 0.18, x + w * 0.82, y + h * 0.78, (8, 8, 9))
    for i in range(6):                                      # gold contacts
        px = x + w * 0.24 + i * (w * 0.52 / 5)
        c.rect(px, y + h * 0.22, px + max(1, w * 0.05), y + h * 0.4, (190, 150, 60))
    c.rect(x + w * 0.38, y + h * 0.78, x + w * 0.62, y + h * 0.92, (8, 8, 9))  # latch notch
    if lit:
        c.rect(x + 1, y + 1, x + w * 0.2, y + h * 0.14, led)


def sfp(c, x, y, w, h):
    c.rrect(x, y, x + w, y + h, 2, (60, 62, 66))
    c.rect(x + 3, y + 3, x + w - 3, y + h - 3, (14, 14, 16))
    c.rect(x + 3, y + h * 0.45, x + w - 3, y + h * 0.55, (40, 42, 46))


def screen_ui(c, x0, y0, x1, y1, scale=1.0):
    """generic network dashboard: header bar, throughput graph, status dots (no text)"""
    c.vgrad(x0, y0, x1, y1, (8, 18, 40), (4, 10, 26))
    w, h = x1 - x0, y1 - y0
    c.rect(x0, y0, x1, y0 + h * 0.18, (20, 90, 200))                       # header
    c.circle(x0 + h * 0.09 + 2, y0 + h * 0.09, max(1.5, h * 0.05), (230, 240, 255))
    for i in range(3):
        c.rect(x0 + w * (0.3 + i * 0.18), y0 + h * 0.07, x0 + w * (0.42 + i * 0.18), y0 + h * 0.11, (170, 205, 255))
    import random
    rnd = random.Random(4)
    base = y0 + h * 0.85
    prev = None
    for i in range(int(w * 0.9)):                                          # throughput graph
        gx = x0 + w * 0.05 + i
        v = 0.3 + 0.25 * math.sin(i / (6 * scale)) + rnd.random() * 0.12
        gy = base - v * h * 0.5
        c.rect(gx, gy, gx + 1, base, (40, 140, 255), 0.35)
        c.rect(gx, gy, gx + 1, gy + max(1, h * 0.02), (90, 190, 255))
    for i in range(4):                                                     # client dots
        c.circle(x1 - w * 0.08 - i * h * 0.12, y0 + h * 0.3, max(1.2, h * 0.035), (60, 220, 120) if i < 3 else (255, 190, 60))


# ---------------------------------------------------------------------------
# textures
# ---------------------------------------------------------------------------

# UDM Pro front panel, 1024 x 104  (442 mm x 44 mm)
F = Canvas(1024, 104, (196, 199, 204))
F.brushed(5)
F.rect(0, 0, 1024, 3, (230, 232, 235)); F.rect(0, 101, 1024, 104, (120, 122, 128))
F.rrect(40, 16, 176, 88, 6, (10, 10, 12))                                  # touchscreen bezel
F.rect(48, 22, 168, 82, (0, 0, 0))                                         # (screen quad covers this)
F.rrect(222, 14, 520, 90, 5, (150, 153, 158)); F.rrect(228, 20, 514, 84, 3, (176, 179, 184))   # 3.5" drive bay
for i in range(46):
    F.rect(236 + i * 6, 34, 239 + i * 6, 70, (120, 123, 128))               # bay vent slots
F.rrect(470, 40, 506, 64, 4, (60, 62, 66))                                 # bay latch
F.circle(540, 30, 3, (60, 220, 90)); F.circle(540, 74, 3, (40, 140, 255))  # status LEDs
for row in range(2):                                                       # 8 x LAN (2 rows)
    for col in range(4):
        rj45(F, 572 + col * 52, 12 + row * 42, 44, 36, lit=(row + col) % 3 != 2)
rj45(F, 790, 12, 44, 36, led=(255, 170, 40))                               # WAN
for i in range(2):                                                         # 2 x SFP+
    sfp(F, 860 + i * 70, 18, 60, 30)
    F.circle(890 + i * 70, 64, 3, (60, 220, 90) if i == 0 else (70, 70, 74))
F.noise(2)
F.save_dds(os.path.join(TEX, 'opslabs_udm_front.dds'))

# UDM Pro chassis (dark grey with perforated vent pattern)
B = Canvas(128, 128, (52, 54, 58))
for y in range(4, 128, 8):
    for x in range(4 + (y // 8 % 2) * 4, 128, 8):
        B.circle(x, y, 1.6, (24, 25, 28))
B.noise(3)
B.save_dds(os.path.join(TEX, 'opslabs_udm_body.dds'))

# UDM Pro touchscreen (emissive)
S = Canvas(128, 64, (0, 0, 0))
screen_ui(S, 0, 0, 128, 64)
S.save_dds(os.path.join(TEX, 'opslabs_udm_screen.dds'))

# Cloud Gateway Ultra: white plastic
W = Canvas(64, 64, (240, 241, 239)); W.noise(2); W.save_dds(os.path.join(TEX, 'opslabs_ucg_body.dds'))

# Ultra front: white with a small dark display window, 256 x 54 (142 mm x 30 mm)
UF = Canvas(256, 54, (240, 241, 239))
UF.rrect(98, 14, 158, 40, 4, (14, 14, 16))
UF.rect(0, 50, 256, 54, (210, 212, 210))
UF.noise(2)
UF.save_dds(os.path.join(TEX, 'opslabs_ucg_front.dds'))

# Ultra back: 4 x LAN + WAN + USB-C power, 256 x 54
UB = Canvas(256, 54, (232, 233, 231))
for i in range(5):
    rj45(UB, 22 + i * 36, 12, 30, 26, led=(255, 170, 40) if i == 4 else (60, 220, 90))
UB.rrect(212, 20, 236, 30, 5, (30, 30, 32)); UB.rrect(215, 22, 233, 28, 3, (70, 72, 76))  # USB-C
UB.noise(2)
UB.save_dds(os.path.join(TEX, 'opslabs_ucg_back.dds'))

# Ultra status display (emissive)
US = Canvas(64, 32, (0, 0, 0))
screen_ui(US, 0, 0, 64, 32, 0.5)
US.save_dds(os.path.join(TEX, 'opslabs_ucg_screen.dds'))


# ---------------------------------------------------------------------------
# materials
# ---------------------------------------------------------------------------

def material(shader, dds, emissive=None):
    mat = sz_mats.create_shader(shader)
    mat.name = os.path.splitext(dds)[0]
    img = bpy.data.images.load(os.path.join(TEX, dds), check_existing=True)
    img.name = os.path.splitext(dds)[0]
    for node in mat.node_tree.nodes:
        if isinstance(node, bpy.types.ShaderNodeTexImage) and node.name == 'DiffuseSampler':
            node.image = img
            node.texture_properties.embedded = True
    if emissive is not None:
        n = mat.node_tree.nodes.get('emissiveMultiplier')
        if n is not None:
            try:
                n.set('X', emissive)
            except Exception:
                pass
    return mat


M = {
    'udm_front': material('default.sps', 'opslabs_udm_front.dds'),
    'udm_body': material('default.sps', 'opslabs_udm_body.dds'),
    'udm_screen': material('emissive.sps', 'opslabs_udm_screen.dds', 3.0),
    'ucg_body': material('default.sps', 'opslabs_ucg_body.dds'),
    'ucg_front': material('default.sps', 'opslabs_ucg_front.dds'),
    'ucg_back': material('default.sps', 'opslabs_ucg_back.dds'),
    'ucg_screen': material('emissive.sps', 'opslabs_ucg_screen.dds', 3.0),
}


# ---------------------------------------------------------------------------
# geometry helpers (meshes with UVMap 0 + Color 1, as Sollumz expects)
# ---------------------------------------------------------------------------

def new_obj(name, bm, mats, smooth=False):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for m in mats:
        me.materials.append(m)
    if 'Color 1' not in me.color_attributes:
        col = me.color_attributes.new('Color 1', 'BYTE_COLOR', 'CORNER')
        for d in col.data:
            d.color = (1, 1, 1, 1)
    for p in me.polygons:
        p.use_smooth = smooth
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def quad(bm, uv, verts, mat_index=0):
    """quad with full 0..1 UVs (verts in order: bottom-left, bottom-right, top-right, top-left)"""
    vs = [bm.verts.new(v) for v in verts]
    f = bm.faces.new(vs)
    f.material_index = mat_index
    for loop, (u, v) in zip(f.loops, ((0, 0), (1, 0), (1, 1), (0, 1))):
        loop[uv].uv = (u, v)
    return f


def box(bm, uv, x0, y0, z0, x1, y1, z1, mat_index=0, skip=()):
    """axis aligned box; skip = faces to leave open ('front' = -Y, 'back' = +Y)"""
    faces = {
        'front': [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
        'back': [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
        'left': [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
        'right': [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        'top': [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
        'bottom': [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
    }
    for k, v in faces.items():
        if k not in skip:
            quad(bm, uv, v, mat_index)


# ---------------------------------------------------------------------------
# UDM Pro — 442 x 285 x 43.7 mm chassis + rack ears (482.6 mm overall)
# ---------------------------------------------------------------------------

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)


def build_udm():
    W, D, H = 0.442, 0.285, 0.0437
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap 0')
    x0, x1 = -W / 2, W / 2
    y0, y1 = -D / 2, D / 2
    box(bm, uv, x0, y0, 0.0, x1, y1, H, mat_index=1, skip=('front',))      # chassis (front left open)
    quad(bm, uv, [(x0, y0, 0.0), (x1, y0, 0.0), (x1, y0, H), (x0, y0, H)], 0)  # front panel texture
    # touchscreen (emissive, 0.5 mm proud of the panel) — matches the bezel in the front texture
    sx0, sx1 = x0 + W * (48 / 1024), x0 + W * (168 / 1024)
    sz0, sz1 = H * (1 - 82 / 104), H * (1 - 22 / 104)
    quad(bm, uv, [(sx0, y0 - 0.0005, sz0), (sx1, y0 - 0.0005, sz0), (sx1, y0 - 0.0005, sz1), (sx0, y0 - 0.0005, sz1)], 2)
    # rack ears (brushed front-panel metal), 20 mm each, with two mounting slots
    for side in (-1, 1):
        ex0 = x0 - 0.0203 if side < 0 else x1
        ex1 = x0 if side < 0 else x1 + 0.0203
        box(bm, uv, ex0, y0, 0.0, ex1, y0 + 0.002, H, mat_index=1)
    return new_obj('opslabs_udm_pro', bm, [M['udm_front'], M['udm_body'], M['udm_screen']])


# ---------------------------------------------------------------------------
# Cloud Gateway Ultra — 141.8 x 127.6 x 30 mm, rounded white box
# ---------------------------------------------------------------------------

def build_ucg():
    W, D, H = 0.1418, 0.1276, 0.030
    R = 0.012
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new('UVMap 0')
    # rounded rectangle footprint extruded up (body material, smooth sides)
    seg = 8
    pts = []
    for cx, cy, a0 in ((W / 2 - R, -D / 2 + R, -90), (W / 2 - R, D / 2 - R, 0), (-W / 2 + R, D / 2 - R, 90), (-W / 2 + R, -D / 2 + R, 180)):
        for i in range(seg + 1):
            a = math.radians(a0 + 90 * i / seg)
            pts.append((cx + R * math.cos(a), cy + R * math.sin(a)))
    bottom = [bm.verts.new((x, y, 0.0015)) for x, y in pts]
    top = [bm.verts.new((x, y, H)) for x, y in pts]
    n = len(pts)
    for i in range(n):
        f = bm.faces.new((bottom[i], bottom[(i + 1) % n], top[(i + 1) % n], top[i]))
        f.material_index = 0
        f.smooth = True
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    ft = bm.faces.new(top); ft.material_index = 0
    fb = bm.faces.new(list(reversed(bottom))); fb.material_index = 0
    for f in (ft, fb):
        for loop in f.loops:
            loop[uv].uv = (0.5, 0.5)
    # grey rubber foot plate
    box(bm, uv, -W / 2 + R, -D / 2 + R, 0.0, W / 2 - R, D / 2 - R, 0.0015, mat_index=0)
    # front + back decal panels on the flat part of the sides (0.3 mm proud)
    fw = W / 2 - R
    quad(bm, uv, [(-fw, -D / 2 - 0.0003, 0.0015), (fw, -D / 2 - 0.0003, 0.0015), (fw, -D / 2 - 0.0003, H), (-fw, -D / 2 - 0.0003, H)], 1)
    quad(bm, uv, [(fw, D / 2 + 0.0003, 0.0015), (-fw, D / 2 + 0.0003, 0.0015), (-fw, D / 2 + 0.0003, H), (fw, D / 2 + 0.0003, H)], 2)
    # status display (emissive) inside the dark window of the front texture
    wx0 = -fw + 2 * fw * (100 / 256); wx1 = -fw + 2 * fw * (156 / 256)
    wz0 = 0.0015 + (H - 0.0015) * (1 - 38 / 54); wz1 = 0.0015 + (H - 0.0015) * (1 - 16 / 54)
    quad(bm, uv, [(wx0, -D / 2 - 0.0006, wz0), (wx1, -D / 2 - 0.0006, wz0), (wx1, -D / 2 - 0.0006, wz1), (wx0, -D / 2 - 0.0006, wz1)], 3)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-7)
    bmesh.ops.recalc_face_normals(bm, faces=[f for f in bm.faces if f.material_index == 0])
    return new_obj('opslabs_ucg_ultra', bm, [M['ucg_body'], M['ucg_front'], M['ucg_back'], M['ucg_screen']])


udm = build_udm()
ucg = build_ucg()

# ---------------------------------------------------------------------------
# Sollumz drawables (+ collision) and ytyp
# ---------------------------------------------------------------------------

scene = bpy.context.scene
scene.auto_create_embedded_col = True
scene.create_seperate_drawables = True
drawables = []
for obj, colmat in ((udm, 'METAL_SOLID_SMALL'), (ucg, 'PLASTIC')):
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.sollumz.converttodrawable()
    d = obj.parent
    drawables.append(d)
    cm = sz_col.create_collision_material_from_index(col_index(colmat))
    for child in d.children_recursive:
        if child.type == 'MESH' and 'poly_mesh' in child.name:
            child.data.materials.clear()
            child.data.materials.append(cm)
print('DRAWABLES', [d.name for d in drawables])

bpy.ops.sollumz.createytyp()
ytyp = scene.ytyps[scene.ytyp_index]
ytyp.name = 'opslabs_network_props'
bpy.ops.object.select_all(action='DESELECT')
for d in drawables:
    d.select_set(True)
bpy.context.view_layer.objects.active = drawables[0]
bpy.ops.sollumz.createarchetypefromselected()
for a in ytyp.archetypes:
    a.lod_dist = 60.0
print('ARCHETYPES', [a.name for a in ytyp.archetypes])

res = bpy.ops.sollumz.export_assets(
    directory=OUT, direct_export=True, use_custom_settings=True,
    target_formats={'CWXML'}, target_versions={'GEN8'},
    limit_to_selected=False, export_ytyps=True,
)
print('EXPORT', res)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, 'opslabs_gateways.blend'))
