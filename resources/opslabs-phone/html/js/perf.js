'use strict';

/* =====================================================================
   Performance profiles + a short benchmark of the player's PC.
   Ultra:       everything on (live blur, full animations)
   Balanced:    solid backgrounds instead of live blur, full animations
   Performance: solid backgrounds and quick fades (low-end PCs)
   The phone renders at the game's frame rate; these profiles control how
   much work each frame costs so it stays smooth on the player's machine.
   ===================================================================== */

const Perf = {
    PRESETS: {
        ultra:       { label: 'Ultra',       icon: 'fa-wand-magic-sparkles', desc: 'Live blur and every animation. For strong PCs.', rt: false, rm: false },
        balanced:    { label: 'Balanced',    icon: 'fa-scale-balanced',      desc: 'Solid backgrounds instead of live blur, full animations.', rt: true, rm: false },
        performance: { label: 'Performance', icon: 'fa-gauge-high',          desc: 'Solid backgrounds and quick fades. For low-end PCs.', rt: true, rm: true },
    },

    current() { return Phone.settings.perf || 'ultra'; },

    /** the settings a preset maps to */
    settingsFor(id) {
        const p = this.PRESETS[id] || this.PRESETS.ultra;
        return { perf: id, reduceTransparency: p.rt, reduceMotion: p.rm };
    },

    apply(id) {
        const s = this.settingsFor(id);
        Object.entries(s).forEach(([k, v]) => { Phone.settings[k] = v; });
        applySettings();
        rpc('saveSettings', s);
    },

    /**
     * Renders a representative workload (blurred layers + transforms) inside
     * `host` for `ms` and measures real frame times.
     * Resolves with { fps, p95, loadMs, recommended }.
     */
    benchmark(host, ms = 1500) {
        return new Promise((resolve) => {
            const t0 = performance.now();
            const stage = el(`<div class="perf-stage">${Array.from({ length: 6 }, (_, i) => `<i style="--i:${i}"></i>`).join('')}<b></b></div>`);
            host.appendChild(stage);
            // load test: time to build + lay out the home screen
            const l0 = performance.now();
            renderHome();
            void $('#home').offsetHeight;
            const loadMs = performance.now() - l0;

            const frames = [];
            let last = performance.now();
            const loop = (t) => {
                frames.push(t - last);
                last = t;
                if (t - t0 < ms) requestAnimationFrame(loop);
                else finish();
            };
            const finish = () => {
                stage.remove();
                frames.shift();
                const sorted = frames.slice().sort((a, b) => a - b);
                const avg = frames.reduce((a, b) => a + b, 0) / Math.max(1, frames.length);
                const p95 = sorted[Math.floor(sorted.length * 0.95)] || avg;
                const fps = Math.round(1000 / avg);
                let recommended = 'performance';
                if (fps >= 55 && p95 < 24) recommended = 'ultra';
                else if (fps >= 40 && p95 < 40) recommended = 'balanced';
                resolve({ fps, p95: Math.round(p95), loadMs: Math.max(1, Math.round(loadMs)), recommended });
            };
            requestAnimationFrame(loop);
        });
    },
};
