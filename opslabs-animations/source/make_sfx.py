"""Synthesises the climbing and harness sounds for opslabs-animations (no samples, no dependencies).

    python3 make_sfx.py ../html/sfx

Every sound is built from damped partials (metal), filtered noise (scuffs, webbing) and low thumps
(boots). Variants use different seeds so repeated steps never sound identical.
"""
import math
import os
import random
import struct
import sys
import wave

RATE = 22050


def buf(seconds):
    return [0.0] * int(RATE * seconds)


def add(dst, src, at=0.0, gain=1.0):
    o = int(at * RATE)
    for i, v in enumerate(src):
        if o + i < len(dst):
            dst[o + i] += v * gain


def ring(freq, partials, seconds, rnd):
    """metal: inharmonic partials (ratio, amplitude, decay seconds), slight detune per hit"""
    out = buf(seconds)
    for ratio, amp, decay in partials:
        f = freq * ratio * (1 + rnd.uniform(-0.01, 0.01))
        ph = rnd.uniform(0, math.tau)
        for i in range(len(out)):
            t = i / RATE
            out[i] += amp * math.exp(-t / decay) * math.sin(math.tau * f * t + ph)
    return out


def thump(freq, decay, seconds, drop=0.5):
    """boot / palm impact: a sine that falls in pitch and dies quickly"""
    out = buf(seconds)
    ph = 0.0
    for i in range(len(out)):
        t = i / RATE
        f = freq * (1 - drop * min(1.0, t / (decay * 3)))
        ph += math.tau * f / RATE
        out[i] = math.exp(-t / decay) * math.sin(ph) * min(1.0, t * 2000)
    return out


def noise(seconds, rnd, attack=0.002, decay=0.03, sustain=0.0):
    out = buf(seconds)
    for i in range(len(out)):
        t = i / RATE
        env = min(1.0, t / attack) * (math.exp(-t / decay) if sustain == 0 else 1.0)
        out[i] = rnd.uniform(-1, 1) * env
    return out


def lowpass(x, cutoff):
    a = 1 - math.exp(-math.tau * cutoff / RATE)
    y, out = 0.0, []
    for v in x:
        y += a * (v - y)
        out.append(y)
    return out


def highpass(x, cutoff):
    lp = lowpass(x, cutoff)
    return [v - l for v, l in zip(x, lp)]


def band(x, lo, hi):
    return lowpass(highpass(x, lo), hi)


def envelope(x, points):
    """points: [(t, gain)], linear between them"""
    out = []
    for i, v in enumerate(x):
        t = i / RATE
        g = points[-1][1]
        for (t0, g0), (t1, g1) in zip(points, points[1:]):
            if t0 <= t <= t1:
                g = g0 + (g1 - g0) * (t - t0) / max(1e-6, t1 - t0)
                break
        out.append(v * g)
    return out


def save(path, x, peak=0.85):
    m = max(1e-6, max(abs(v) for v in x))
    fade = int(0.004 * RATE)
    for i in range(min(fade, len(x))):
        x[-1 - i] *= i / fade
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b''.join(struct.pack('<h', int(max(-1, min(1, v / m * peak)) * 32767)) for v in x))


ALU = [(1.0, 1.0, 0.20), (2.76, 0.55, 0.12), (5.40, 0.30, 0.06), (8.93, 0.15, 0.035)]   # aluminium rung / stile
STEEL = [(1.0, 1.0, 0.07), (1.48, 0.6, 0.05), (2.30, 0.35, 0.03)]                         # small steel parts


def ladder_rung(rnd):
    x = buf(0.45)
    add(x, thump(rnd.uniform(95, 135), 0.035, 0.2), 0.0, 0.9)                 # boot on the rung
    add(x, ring(rnd.uniform(720, 900), ALU, 0.45, rnd), 0.004, 0.32)           # the ladder rings
    add(x, band(noise(0.08, rnd, decay=0.012), 1500, 6000), 0.0, 0.35)         # tread scuff
    if rnd.random() < 0.5:                                                     # stile knock
        add(x, ring(rnd.uniform(380, 460), ALU, 0.3, rnd), rnd.uniform(0.03, 0.06), 0.12)
    return x


def ladder_hand(rnd):
    x = buf(0.2)
    add(x, ring(rnd.uniform(1300, 1600), ALU, 0.2, rnd), 0.0, 0.2)
    add(x, lowpass(noise(0.06, rnd, decay=0.01), 2500), 0.0, 0.5)
    return envelope(x, [(0, 1), (0.05, 0.5), (0.2, 0)])


def pole_step(rnd):
    x = buf(0.35)
    add(x, thump(rnd.uniform(150, 190), 0.045, 0.25, drop=0.35), 0.0, 1.0)     # wood takes the weight
    add(x, ring(rnd.uniform(2100, 2700), STEEL, 0.2, rnd), 0.003, 0.22)        # boot on the steel step bolt
    add(x, band(noise(0.12, rnd, decay=0.035), 600, 3500), 0.0, 0.4)           # sole scuffs on the bolt
    return x


def pole_grip(rnd):
    x = buf(0.18)
    add(x, lowpass(noise(0.12, rnd, decay=0.02), 1800), 0.0, 0.9)              # palm on the wood
    add(x, thump(rnd.uniform(200, 260), 0.025, 0.12), 0.0, 0.5)
    return x


def ping(rnd, lo=2200, hi=5200):
    return ring(rnd.uniform(lo, hi), [(1.0, 1.0, rnd.uniform(0.05, 0.14)), (1.48, 0.5, 0.05), (2.3, 0.25, 0.03)], 0.3, rnd)


def harness_jingle(rnd):
    x = buf(0.55)
    for _ in range(rnd.randint(3, 6)):                                         # D-rings and karabiners knocking
        add(x, ping(rnd), rnd.uniform(0.0, 0.22), rnd.uniform(0.12, 0.3))
    add(x, band(noise(0.35, rnd, attack=0.03, decay=0.12), 800, 4000), 0.0, 0.08)   # webbing
    return x


def harness_clip(rnd):
    x = buf(0.45)
    add(x, highpass(noise(0.01, rnd, decay=0.002), 3000), 0.0, 0.6)            # gate opens
    add(x, ring(3200, STEEL, 0.4, rnd), 0.03, 0.35)                            # snaps on to the strap ring
    add(x, highpass(noise(0.01, rnd, decay=0.0015), 3500), 0.075, 0.8)         # gate closes
    add(x, ring(4100, STEEL, 0.3, rnd), 0.078, 0.25)
    add(x, harness_jingle(rnd), 0.1, 0.25)
    return x


def harness_unclip(rnd):
    x = buf(0.45)
    add(x, highpass(noise(0.01, rnd, decay=0.002), 3000), 0.0, 0.7)
    add(x, ring(2600, STEEL, 0.35, rnd), 0.012, 0.3)
    add(x, highpass(noise(0.01, rnd, decay=0.0015), 3500), 0.11, 0.5)
    add(x, harness_jingle(rnd), 0.13, 0.35)
    return x


def webbing(rnd):
    x = buf(1.0)
    n = band(noise(1.0, rnd, attack=0.05, sustain=1), 500, 3500)
    n = envelope(n, [(0, 0), (0.1, 0.5), (0.35, 0.9), (0.55, 0.4), (0.75, 0.8), (0.95, 0)])
    add(x, n, 0.0, 0.35)
    add(x, ping(rnd, 1800, 2600), 0.82, 0.25)                                  # buckle at the end
    return x


def buckle(rnd):
    x = buf(0.9)
    add(x, webbing(rnd), 0.0, 0.7)
    for t in (0.2, 0.45, 0.6):
        add(x, highpass(noise(0.01, rnd, decay=0.002), 2500), t, 0.5)
        add(x, ping(rnd, 1800, 3000), t + 0.004, 0.2)
    return x


SOUNDS = {
    'ladder_rung': (ladder_rung, 4), 'ladder_hand': (ladder_hand, 2),
    'pole_step': (pole_step, 4), 'pole_grip': (pole_grip, 2),
    'harness_jingle': (harness_jingle, 4), 'harness_clip': (harness_clip, 1), 'harness_unclip': (harness_unclip, 1),
    'webbing': (webbing, 1), 'buckle': (buckle, 1),
}

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else '../html/sfx'
    os.makedirs(out, exist_ok=True)
    for name, (fn, n) in SOUNDS.items():
        for k in range(1, n + 1):
            rnd = random.Random(f'{name}{k}')
            save(os.path.join(out, f'{name}_{k}.wav'), fn(rnd))
            print('wrote', f'{name}_{k}.wav')
