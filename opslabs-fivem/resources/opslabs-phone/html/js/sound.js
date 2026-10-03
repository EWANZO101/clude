'use strict';

/**
 * All phone sounds are synthesized with WebAudio, so the resource ships no
 * audio files: marimba ringtones, tri-tone, keypad DTMF, shutter, lock click.
 */
const Sound = (() => {
    let ctx = null;
    let volume = 0.7;
    let silent = false;
    let ringTimer = null;
    let ringNodes = [];

    const ac = () => {
        if (!ctx) ctx = new (window.AudioContext || window.webkitAudioContext)();
        if (ctx.state === 'suspended') ctx.resume();
        return ctx;
    };

    const hz = (semi) => 440 * Math.pow(2, (semi - 69) / 12); // midi -> Hz

    function out(gain) {
        const c = ac();
        const g = c.createGain();
        g.gain.value = gain * volume;
        g.connect(c.destination);
        return g;
    }

    /** Marimba-ish tone: sine fundamental + fast-decaying 4th harmonic */
    function marimba(midi, t, dur = 0.6, gain = 0.35, track) {
        const c = ac();
        const dest = out(gain);
        [[1, 1], [4, 0.25], [10, 0.05]].forEach(([mult, amp]) => {
            const o = c.createOscillator();
            const g = c.createGain();
            o.type = 'sine';
            o.frequency.value = hz(midi) * mult;
            g.gain.setValueAtTime(0, t);
            g.gain.linearRampToValueAtTime(amp, t + 0.004);
            g.gain.exponentialRampToValueAtTime(0.0001, t + dur / (mult > 1 ? mult * 0.6 : 1));
            o.connect(g).connect(dest);
            o.start(t);
            o.stop(t + dur + 0.05);
            if (track) track.push(o);
        });
    }

    function tone(freqs, dur, { type = 'sine', gain = 0.2, attack = 0.005, release = 0.05, at = 0 } = {}) {
        const c = ac();
        const t = c.currentTime + at;
        const dest = out(gain);
        freqs.forEach((f) => {
            const o = c.createOscillator();
            const g = c.createGain();
            o.type = type;
            o.frequency.value = f;
            g.gain.setValueAtTime(0, t);
            g.gain.linearRampToValueAtTime(1 / freqs.length, t + attack);
            g.gain.setValueAtTime(1 / freqs.length, t + dur - release);
            g.gain.linearRampToValueAtTime(0, t + dur);
            o.connect(g).connect(dest);
            o.start(t);
            o.stop(t + dur + 0.02);
        });
    }

    function noise(dur, { gain = 0.3, filter = 3000, at = 0 } = {}) {
        const c = ac();
        const t = c.currentTime + at;
        const len = Math.floor(c.sampleRate * dur);
        const buf = c.createBuffer(1, len, c.sampleRate);
        const data = buf.getChannelData(0);
        for (let i = 0; i < len; i++) data[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3);
        const src = c.createBufferSource();
        src.buffer = buf;
        const f = c.createBiquadFilter();
        f.type = 'bandpass';
        f.frequency.value = filter;
        src.connect(f).connect(out(gain));
        src.start(t);
    }

    // [midi note, beat offset] patterns, looped while ringing
    const RINGTONES = {
        reflection: { bpm: 300, length: 16, notes: [[76, 0], [83, 1], [80, 2], [88, 3], [83, 4], [80, 5], [76, 6], [80, 7], [76, 8], [83, 9], [80, 10], [88, 11], [87, 12]] },
        opening:    { bpm: 260, length: 16, notes: [[72, 0], [76, 1], [79, 2], [84, 3], [79, 4], [76, 5], [74, 6], [79, 7], [83, 8], [86, 9], [83, 10], [79, 11]] },
        radar:      { bpm: 480, length: 16, notes: [[84, 0], [84, 2], [84, 4], [84, 6], [84, 8], [84, 10], [91, 12], [91, 13]] },
        chime:      { bpm: 200, length: 12, notes: [[79, 0], [76, 1], [72, 2], [79, 4], [76, 5], [72, 6], [84, 8]] },
    };

    function playPattern(p, at) {
        const beat = 60 / p.bpm;
        p.notes.forEach(([n, b]) => marimba(n, at + b * beat, 0.7, 0.3, ringNodes));
        return p.length * beat;
    }

    return {
        setVolume(v) { volume = Math.max(0, Math.min(1, v)); },
        setSilent(s) { silent = !!s; },
        get silent() { return silent; },

        ring(id = 'reflection') {
            this.stopRing();
            if (silent) return false;
            const p = RINGTONES[id] || RINGTONES.reflection;
            const loop = () => {
                const len = playPattern(p, ac().currentTime + 0.05);
                ringTimer = setTimeout(loop, len * 1000 + 400);
            };
            loop();
            return true;
        },
        preview(id) {
            this.stopRing();
            const p = RINGTONES[id] || RINGTONES.reflection;
            playPattern(p, ac().currentTime + 0.05);
        },
        stopRing() {
            clearTimeout(ringTimer);
            ringTimer = null;
            ringNodes.forEach((o) => { try { o.stop(); } catch (_) { /* already stopped */ } });
            ringNodes = [];
        },

        /** outgoing ringback tone (US: 440+480Hz, 2s on / 4s off) */
        ringback() {
            this.stopRing();
            const loop = () => {
                tone([440, 480], 2, { gain: 0.08 });
                ringTimer = setTimeout(loop, 6000);
            };
            loop();
        },

        play(name, arg) {
            if (silent && !['key', 'lock', 'shutter'].includes(name)) return;
            const t = ac().currentTime;
            switch (name) {
                case 'message': // tri-tone
                    marimba(88, t, 0.35, 0.25); marimba(86, t + 0.12, 0.35, 0.25); marimba(91, t + 0.24, 0.6, 0.25);
                    break;
                case 'notify':
                    marimba(84, t, 0.4, 0.25); marimba(91, t + 0.1, 0.6, 0.22);
                    break;
                case 'sent':
                    tone([600], 0.12, { gain: 0.06, type: 'sine' });
                    tone([1200], 0.1, { gain: 0.04, at: 0.05 });
                    break;
                case 'key': {
                    const dtmf = { 1: [697, 1209], 2: [697, 1336], 3: [697, 1477], 4: [770, 1209], 5: [770, 1336], 6: [770, 1477], 7: [852, 1209], 8: [852, 1336], 9: [852, 1477], '*': [941, 1209], 0: [941, 1336], '#': [941, 1477] };
                    tone(dtmf[arg] || [941, 1336], 0.14, { gain: 0.12 });
                    break;
                }
                case 'lock':
                    noise(0.04, { gain: 0.5, filter: 1800 });
                    break;
                case 'unlock':
                    noise(0.03, { gain: 0.25, filter: 4000 });
                    break;
                case 'shutter':
                    noise(0.06, { gain: 0.6, filter: 2500 });
                    noise(0.08, { gain: 0.5, filter: 1500, at: 0.08 });
                    break;
                case 'alarm':
                    for (let i = 0; i < 4; i++) { marimba(93, t + i * 0.5, 0.25, 0.35); marimba(93, t + i * 0.5 + 0.15, 0.25, 0.35); }
                    break;
                case 'end':
                    tone([480, 620], 0.25, { gain: 0.06 });
                    tone([480, 620], 0.25, { gain: 0.06, at: 0.4 });
                    break;
                case 'pay':
                    marimba(84, t, 0.25, 0.3); marimba(91, t + 0.09, 0.5, 0.3);
                    break;
            }
        },
    };
})();
