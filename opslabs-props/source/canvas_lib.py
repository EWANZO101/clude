import math, struct

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


