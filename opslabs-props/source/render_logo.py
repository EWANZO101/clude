"""Render the OPS Network logo artwork with real fonts (DejaVu Sans) to transparent PNGs.
blender -b --python render_logo.py -- <out_dir>"""
import bpy, bmesh, math, os, sys
OUT = sys.argv[sys.argv.index('--') + 1]
os.makedirs(OUT, exist_ok=True)
BOLD = bpy.data.fonts.load('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf')
REG = bpy.data.fonts.load('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')

def srgb(h):
    h = h.lstrip('#'); c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return [((x + 0.055) / 1.055) ** 2.4 if x > 0.04045 else x / 12.92 for x in c] + [1.0]

def emit(color):
    m = bpy.data.materials.new('m'); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    e = nt.nodes.new('ShaderNodeEmission'); e.inputs['Color'].default_value = srgb(color); e.inputs['Strength'].default_value = 1.0
    o = nt.nodes.new('ShaderNodeOutputMaterial'); nt.links.new(e.outputs[0], o.inputs[0])
    return m

def reset():
    for o in list(bpy.data.objects): bpy.data.objects.remove(o, do_unlink=True)

def text(s, x, y, size, color, font=BOLD, align='LEFT', spacing=1.0):
    cu = bpy.data.curves.new('t', 'FONT'); cu.body = s; cu.font = font; cu.size = size; cu.align_x = align; cu.space_character = spacing
    o = bpy.data.objects.new('t', cu); o.location = (x, y, 0); bpy.context.scene.collection.objects.link(o)
    o.data.materials.append(emit(color)); return o

def rect(x0, y0, x1, y1, color, r=0.0):
    me = bpy.data.meshes.new('r'); bm = bmesh.new()
    pts = []
    if r <= 0:
        pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    else:
        for (cx, cy, a0) in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
            for k in range(9):
                a = math.radians(a0 + k * 90 / 8); pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    bm.faces.new([bm.verts.new((px, py, -0.01)) for px, py in pts]); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new('r', me); bpy.context.scene.collection.objects.link(o); o.data.materials.append(emit(color)); return o

def signal(cx, cy, s, color):
    """network / signal mark: a dot and three arcs opening up-right"""
    me = bpy.data.meshes.new('s'); bm = bmesh.new()
    n = 24
    ring = [bm.verts.new((cx + math.cos(2 * math.pi * k / n) * 0.16 * s, cy + math.sin(2 * math.pi * k / n) * 0.16 * s, 0)) for k in range(n)]
    bm.faces.new(ring)
    for i, rr in enumerate((0.42, 0.68, 0.94)):
        w = 0.13 * s; a0, a1 = math.radians(-5), math.radians(95); seg = 16
        inner = [(cx + math.cos(a0 + (a1 - a0) * k / seg) * (rr * s - w / 2), cy + math.sin(a0 + (a1 - a0) * k / seg) * (rr * s - w / 2)) for k in range(seg + 1)]
        outer = [(cx + math.cos(a0 + (a1 - a0) * k / seg) * (rr * s + w / 2), cy + math.sin(a0 + (a1 - a0) * k / seg) * (rr * s + w / 2)) for k in range(seg + 1)]
        vi = [bm.verts.new((x, y, 0)) for x, y in inner]; vo = [bm.verts.new((x, y, 0)) for x, y in outer]
        for k in range(seg): bm.faces.new((vi[k], vi[k + 1], vo[k + 1], vo[k]))
    bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new('s', me); bpy.context.scene.collection.objects.link(o); o.data.materials.append(emit(color)); return o

def render(name, w, h, scale):
    sc = bpy.context.scene
    cam = bpy.data.objects.new('c', bpy.data.cameras.new('c')); sc.collection.objects.link(cam); sc.camera = cam
    cam.data.type = 'ORTHO'; cam.data.ortho_scale = scale; cam.location = (0, 0, 10)
    sc.render.engine = 'CYCLES'; sc.cycles.samples = 24; sc.cycles.use_denoising = False; sc.render.film_transparent = True
    sc.render.resolution_x, sc.render.resolution_y = w, h; sc.render.image_settings.file_format = 'PNG'; sc.render.image_settings.color_mode = 'RGBA'
    sc.view_settings.view_transform = 'Standard'
    sc.render.filepath = os.path.join(OUT, name + '.png'); bpy.ops.render.render(write_still=True)

WHITE, YELLOW, BLUE, NAVY = '#ffffff', '#ffc400', '#0a6ee0', '#0b2a5b'
# back print 1024 x 512 (8 x 4 units): mark + OPS, NETWORK spaced out, bar, strapline — all centred
reset()
signal(-2.3, 0.42, 1.0, YELLOW)
text('OPS', -1.05, 0.45, 1.45, WHITE)
text('NETWORK', 0.0, -0.42, 0.6, WHITE, REG, 'CENTER', 1.55)
rect(-2.45, -0.72, 2.45, -0.62, YELLOW)
text('FIBRE  ·  POWER  ·  MOBILE', 0.0, -1.32, 0.33, WHITE, BOLD, 'CENTER', 1.2)
render('uni_back', 1024, 512, 8.0)
# chest print 512 x 256 (4 units wide)
reset()
signal(-1.62, -0.35, 0.72, YELLOW)
text('OPS', -0.8, -0.05, 0.78, WHITE)
text('NETWORK', -0.8, -0.62, 0.4, WHITE, REG, 'LEFT', 1.25)
render('uni_chest', 512, 256, 4.0)
# hard hat sticker 512 x 256 (blue on the white hat)
reset()
signal(-1.62, -0.35, 0.72, BLUE)
text('OPS', -0.8, -0.05, 0.78, NAVY)
text('NETWORK', -0.8, -0.62, 0.4, NAVY, REG, 'LEFT', 1.25)
render('uni_hat', 512, 256, 4.0)
print('LOGOS DONE')
