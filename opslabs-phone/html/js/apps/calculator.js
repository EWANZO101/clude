'use strict';

Apps.register({
    id: 'calculator',
    name: 'Calculator',
    dark: true,
    splash: '#000',
    icon: {
        bg: 'linear-gradient(180deg,#3a3a3c,#1c1c1e)',
        html: () => `<div style="display:grid;grid-template-columns:repeat(2,17px);gap:5px">
            <i style="width:17px;height:17px;border-radius:50%;background:#d4d4d2;display:block"></i>
            <i style="width:17px;height:17px;border-radius:50%;background:#ff9f0a;display:block"></i>
            <i style="width:17px;height:17px;border-radius:50%;background:#505050;display:block"></i>
            <i style="width:17px;height:17px;border-radius:50%;background:#ff9f0a;display:block"></i></div>`,
    },
    open(root) {
        root.innerHTML = `
            <div class="calc">
                <div class="calc-display"><span>0</span></div>
                <div class="calc-keys">
                    <button class="k fn" data-k="clear">AC</button>
                    <button class="k fn" data-k="neg"><i class="fa-solid fa-plus-minus"></i></button>
                    <button class="k fn" data-k="pct"><i class="fa-solid fa-percent"></i></button>
                    <button class="k op" data-k="/"><i class="fa-solid fa-divide"></i></button>
                    <button class="k" data-k="7">7</button><button class="k" data-k="8">8</button><button class="k" data-k="9">9</button>
                    <button class="k op" data-k="*"><i class="fa-solid fa-xmark"></i></button>
                    <button class="k" data-k="4">4</button><button class="k" data-k="5">5</button><button class="k" data-k="6">6</button>
                    <button class="k op" data-k="-"><i class="fa-solid fa-minus"></i></button>
                    <button class="k" data-k="1">1</button><button class="k" data-k="2">2</button><button class="k" data-k="3">3</button>
                    <button class="k op" data-k="+"><i class="fa-solid fa-plus"></i></button>
                    <button class="k" data-k="back"><i class="fa-solid fa-delete-left" style="font-size:26px"></i></button>
                    <button class="k" data-k="0">0</button><button class="k" data-k=".">.</button>
                    <button class="k op" data-k="="><i class="fa-solid fa-equals"></i></button>
                </div>
            </div>`;

        let cur = '0', acc = null, op = null, fresh = true, lastOp = null, lastVal = null;
        const disp = $('.calc-display span', root);

        const fmt = (s) => {
            if (s === 'Error') return s;
            const n = Number(s);
            if (!isFinite(n)) return 'Error';
            if (/e/.test(String(n)) || Math.abs(n) >= 1e9) return n.toExponential(4).replace('+', '');
            const [i, d] = s.split('.');
            const int = Number(i).toLocaleString('en-US');
            return (s.startsWith('-') && int[0] !== '-' ? '-' : '') + int + (d !== undefined ? '.' + d : '');
        };
        const calc = (a, b, o) => {
            switch (o) {
                case '+': return a + b;
                case '-': return a - b;
                case '*': return a * b;
                case '/': return b === 0 ? NaN : a / b;
            }
            return b;
        };
        const clean = (n) => (isFinite(n) ? String(parseFloat(n.toPrecision(12))) : 'Error');
        const draw = () => {
            const text = fmt(cur);
            disp.textContent = text;
            disp.style.fontSize = text.length > 9 ? Math.max(40, 88 - (text.length - 9) * 8) + 'px' : '88px';
            $('[data-k=clear]', root).textContent = cur !== '0' && !fresh ? 'C' : 'AC';
            $$('.op', root).forEach((b) => b.classList.toggle('on', fresh && op === b.dataset.k && b.dataset.k !== '='));
        };

        root.addEventListener('click', (e) => {
            const b = e.target.closest('[data-k]');
            if (!b) return;
            const k = b.dataset.k;
            if (/^\d$/.test(k)) {
                if (fresh) { cur = k; fresh = false; } else if (cur.replace(/[-.]/g, '').length < 9) cur = cur === '0' ? k : cur + k;
            } else if (k === '.') {
                if (fresh) { cur = '0.'; fresh = false; } else if (!cur.includes('.')) cur += '.';
            } else if (k === 'clear') {
                if (cur !== '0' && !fresh) { cur = '0'; fresh = true; } else { cur = '0'; acc = null; op = null; fresh = true; }
            } else if (k === 'neg') {
                cur = cur.startsWith('-') ? cur.slice(1) : (cur === '0' ? cur : '-' + cur);
            } else if (k === 'pct') {
                cur = clean(Number(cur) / 100);
            } else if (k === 'back') {
                if (!fresh) cur = cur.length > 1 && cur !== '-0' ? cur.slice(0, -1) : '0';
                if (cur === '-') cur = '0';
            } else if (k === '=') {
                if (op !== null && acc !== null) {
                    lastVal = Number(cur); lastOp = op;
                    cur = clean(calc(acc, lastVal, op));
                    acc = null; op = null;
                } else if (lastOp) {
                    cur = clean(calc(Number(cur), lastVal, lastOp));
                }
                fresh = true;
            } else {
                if (op && !fresh && acc !== null) { cur = clean(calc(acc, Number(cur), op)); }
                acc = Number(cur);
                op = k;
                fresh = true;
            }
            draw();
        });
        draw();
    },
});
