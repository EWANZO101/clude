/* OPS Guide — chapters of animated slides. Drawings are inline SVG with CSS animations. */
(() => {
  const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'opslabs-guide';
  const post = (name, body) => fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) }).catch(() => {});
  const K = (k) => `<kbd>${k}</kbd>`;

  // ------------------------------------------------------------------ drawings
  const svg = (inner) => `<svg viewBox="0 0 400 250" xmlns="http://www.w3.org/2000/svg">${inner}</svg>`;
  const phone = (x, y, inner = '') => `<g transform="translate(${x} ${y})"><rect width="92" height="170" rx="18" fill="#1b1b24" stroke="#3b3b4a" stroke-width="3"/><rect x="8" y="12" width="76" height="146" rx="10" fill="#0d0d14"/>${inner}</g>`;
  const bars = (x, y, n, col = '#30d158') => [0, 1, 2, 3].map((i) => `<rect x="${x + i * 9}" y="${y - (i + 1) * 6}" width="6" height="${(i + 1) * 6}" rx="1.5" fill="${i < n ? col : '#2e2e3a'}"/>`).join('');
  const pole = (x, base, h, col = '#7a5534') => `<rect x="${x - 5}" y="${base - h}" width="10" height="${h}" rx="3" fill="${col}"/>` +
    Array.from({ length: Math.floor((h - 50) / 22) }, (_, i) => `<rect x="${i % 2 ? x + 4 : x - 14}" y="${base - 46 - i * 22}" width="10" height="3" rx="1" fill="#9aa"/>`).join('');
  const person = (x, y, cls = '') => `<g class="${cls}" transform="translate(${x} ${y})"><circle cx="0" cy="-34" r="7" fill="#ffcf9e"/><rect x="-7" y="-27" width="14" height="22" rx="5" fill="#ff9f0a"/><rect x="-6" y="-6" width="5" height="18" rx="2" fill="#2b3a55"/><rect x="1" y="-6" width="5" height="18" rx="2" fill="#2b3a55"/><rect x="-12" y="-26" width="5" height="16" rx="2" fill="#ff9f0a"/><rect x="7" y="-26" width="5" height="16" rx="2" fill="#ff9f0a"/></g>`;
  const ground = `<rect x="0" y="210" width="400" height="40" fill="#191920"/><line x1="0" y1="210" x2="400" y2="210" stroke="#2c2c38" stroke-width="2"/>`;
  const wall = `<rect x="290" y="40" width="110" height="170" fill="#22222c"/><g stroke="#2a2a35" stroke-width="2">${[60, 90, 120, 150, 180].map((y) => `<line x1="290" y1="${y}" x2="400" y2="${y}"/>`).join('')}</g>`;
  const ont = (x, y, leds = ['g', 'g', '', 'g', 'g']) => `<g transform="translate(${x} ${y})"><rect width="110" height="56" rx="10" fill="#efefec"/>${leds.map((l, i) => `<circle cx="${16 + i * 19.5}" cy="22" r="5" fill="${l === 'r' ? '#ff453a' : l ? '#30d158' : '#3a3a40'}" class="${l === 'b' ? 'a-blink' : ''}"/>`).join('')}${['PWR', 'PON', 'LOS', 'LAN', 'NET'].map((t, i) => `<text x="${16 + i * 19.5}" y="44" font-size="7" font-weight="700" text-anchor="middle" fill="#666">${t}</text>`).join('')}</g>`;
  const box = (x, y, label, col = '#2f6fd6') => `<g transform="translate(${x} ${y})"><rect width="64" height="50" rx="4" fill="#b98c5d"/><rect y="0" width="64" height="8" fill="${col}"/><rect y="42" width="64" height="8" fill="${col}"/><text x="32" y="31" font-size="11" font-weight="800" text-anchor="middle" fill="${col}">${label}</text></g>`;

  const ART = {
    esim: () => svg(phone(154, 40, `<rect x="18" y="40" width="56" height="56" rx="6" fill="#fff"/><g fill="#111">${Array.from({ length: 36 }, (_, i) => (i * 7) % 3 ? `<rect x="${22 + (i % 6) * 8}" y="${44 + Math.floor(i / 6) * 8}" width="7" height="7"/>` : '').join('')}</g><text x="46" y="118" font-size="10" fill="#9a9aa6" text-anchor="middle">eSIM ready</text>${bars(28, 140, 4)}`) +
      `<g class="a-slide"><rect x="40" y="96" width="70" height="44" rx="8" fill="#0a84ff"/><text x="75" y="123" font-size="12" font-weight="700" fill="#fff" text-anchor="middle">PLAN</text></g>`),
    nosignal: () => svg(phone(154, 40, `${bars(30, 60, 0)}<text x="46" y="82" font-size="11" fill="#ff453a" text-anchor="middle" font-weight="700">No service</text><circle cx="46" cy="120" r="20" fill="#ff453a" class="a-pulse"/><text x="46" y="125" font-size="12" font-weight="800" fill="#fff" text-anchor="middle">SOS</text>`) +
      `<g stroke="#ff453a" stroke-width="4" stroke-linecap="round"><line x1="90" y1="80" x2="120" y2="110"/><line x1="120" y1="80" x2="90" y2="110"/></g>`),
    wifi: () => svg(phone(60, 40, `<text x="46" y="60" font-size="10" fill="#9a9aa6" text-anchor="middle">Wi-Fi</text><rect x="14" y="70" width="64" height="22" rx="6" fill="#1d1d26"/><text x="22" y="85" font-size="9" fill="#fff">OfficeNet 🔒</text><rect x="14" y="98" width="64" height="22" rx="6" fill="#1d1d26"/><text x="22" y="113" font-size="9" fill="#9a9aa6">Cafe Free</text>`) +
      `<g transform="translate(290 140)"><rect x="-30" y="0" width="60" height="18" rx="5" fill="#2a2a35"/><circle cx="-14" cy="9" r="2.5" fill="#30d158"/>${[30, 55, 80].map((r, i) => `<circle cx="0" cy="0" r="${r}" fill="none" stroke="#30d158" stroke-width="3" class="a-wave" style="animation-delay:${i * .6}s"/>`).join('')}</g>`),
    store: () => svg(phone(154, 40, `${['#0a84ff', '#30d158', '#ff9f0a', '#ff375f', '#8e7dff', '#64d2ff'].map((c, i) => `<rect x="${16 + (i % 3) * 22}" y="${28 + Math.floor(i / 3) * 24}" width="16" height="16" rx="4" fill="${c}" class="${i === 0 ? 'a-pulse' : ''}"/>`).join('')}<text x="46" y="110" font-size="9" fill="#9a9aa6" text-anchor="middle">OPS Mobile</text>`)),
    menu: () => svg(`<rect x="110" y="30" width="180" height="190" rx="14" fill="#1b1b24" stroke="#33333f"/><text x="126" y="58" font-size="13" font-weight="700" fill="#fff">OPS Mobile · Network</text>` +
      ['Signal here · 3/4', 'Place a cell tower', 'Place a Wi-Fi AP', 'Towers & access points', 'Bulk actions', 'Cabling & equipment'].map((t, i) => `<rect x="122" y="${70 + i * 24}" width="156" height="20" rx="6" fill="${i === 1 ? '#0a84ff' : '#24242f'}" class="${i === 1 ? 'a-pulse' : ''}"/><text x="132" y="${84 + i * 24}" font-size="10" fill="#e8e8ee">${t}</text>`).join('')),
    aim: () => svg(ground + `<g opacity=".55"><rect x="182" y="150" width="36" height="60" rx="4" fill="#0a84ff"/><circle cx="200" cy="140" r="16" fill="none" stroke="#0a84ff" stroke-width="4"/></g><g stroke="#fff" stroke-width="2"><line x1="200" y1="96" x2="200" y2="112"/><line x1="200" y1="124" x2="200" y2="138"/><line x1="176" y1="118" x2="190" y2="118"/><line x1="210" y1="118" x2="224" y2="118"/></g><path d="M150 205 A50 18 0 0 0 250 205" fill="none" stroke="#ffd60a" stroke-width="3" class="a-dash"/><text x="200" y="238" font-size="11" fill="#9a9aa6" text-anchor="middle">scroll / Q · E rotate · ↑ ↓ height</text>`),
    coverage: () => svg(`<rect x="20" y="20" width="360" height="210" rx="16" fill="#151d2b"/>` + [[120, 120, 70, '#0a84ff'], [250, 110, 50, '#30d158'], [300, 170, 30, '#ff453a']].map(([x, y, r, c], i) => `<circle cx="${x}" cy="${y}" r="${r}" fill="${c}" opacity=".18"/><circle cx="${x}" cy="${y}" r="${r}" fill="none" stroke="${c}" stroke-width="2" class="a-pulse" style="animation-delay:${i * .5}s"/><circle cx="${x}" cy="${y}" r="5" fill="${c}"/>`).join('')),
    map: () => svg(`<rect x="20" y="20" width="360" height="210" rx="16" fill="#e9ecef"/><g stroke="#cfd4da" stroke-width="6">${[70, 140, 200].map((y) => `<line x1="20" y1="${y}" x2="380" y2="${y}"/>`).join('')}${[110, 230, 320].map((x) => `<line x1="${x}" y1="20" x2="${x}" y2="230"/>`).join('')}</g><g class="a-slide"><circle cx="150" cy="110" r="10" fill="#0a84ff" stroke="#fff" stroke-width="3"/></g><circle cx="280" cy="170" r="8" fill="#30d158" stroke="#fff" stroke-width="3"/>`),
    box: () => svg(ground + box(90, 160, 'CAT6') + `<path d="M122 160 C 130 120, 200 200, 300 150" fill="none" stroke="#111" stroke-width="5" class="a-draw"/>` + person(310, 200)),
    route: () => svg(wall + ground + `<polyline points="40,205 150,205 300,205 300,90 360,90" fill="none" stroke="#111" stroke-width="5" class="a-draw"/>` + [[40, 205], [150, 205], [300, 205], [300, 90], [360, 90]].map(([x, y], i) => `<circle cx="${x}" cy="${y}" r="5" fill="#fff" class="a-pop" style="animation-delay:${i * .25}s"/>`).join('') + `<text x="150" y="238" font-size="11" fill="#9a9aa6" text-anchor="middle">LMB fix · Shift straight · Enter connect</text>`),
    rj45: () => {
      const cols = [['#f7c08a', 1], ['#ff8a00', 0], ['#a8e6a1', 1], ['#1f6fff', 0], ['#9ec5ff', 1], ['#20b04b', 0], ['#d8b89a', 1], ['#7b4a24', 0]];
      return svg(`<rect x="120" y="40" width="160" height="110" rx="10" fill="#d9dde2" opacity=".9"/><rect x="120" y="150" width="160" height="50" rx="6" fill="#222"/>` + cols.map(([c, w], i) => `<g class="a-pop" style="animation-delay:${i * .18}s"><rect x="${134 + i * 17}" y="60" width="11" height="120" rx="5" fill="${c}"/>${w ? `<rect x="${134 + i * 17}" y="60" width="11" height="120" rx="5" fill="url(#st)"/>` : ''}<text x="${139.5 + i * 17}" y="54" font-size="9" fill="#fff" text-anchor="middle">${i + 1}</text></g>`).join('') +
        `<defs><pattern id="st" width="11" height="10" patternUnits="userSpaceOnUse"><rect width="11" height="5" fill="#fff" opacity=".85"/></pattern></defs><text x="200" y="230" font-size="12" fill="#9a9aa6" text-anchor="middle">T568B — pins 1 to 8</text>`);
    },
    trunk: () => svg(wall + `<rect x="300" y="120" width="100" height="16" rx="3" fill="#f4f4f0"/><rect x="40" y="120" width="260" height="16" rx="3" fill="#f4f4f0" opacity=".25"/><path d="M40 128 H300" stroke="#111" stroke-width="4" class="a-draw"/><text x="170" y="170" font-size="11" fill="#9a9aa6" text-anchor="middle">aim at trunking while pulling — the cable goes inside</text>`),
    splice: () => svg(`<line x1="40" y1="125" x2="190" y2="125" stroke="#ffd60a" stroke-width="5" class="a-slide"/><line x1="210" y1="125" x2="360" y2="125" stroke="#ffd60a" stroke-width="5"/><circle cx="200" cy="125" r="14" fill="#fff" class="a-blink"/><rect x="150" y="60" width="100" height="36" rx="8" fill="#2a2a35"/><text x="200" y="83" font-size="12" font-weight="700" fill="#30d158" text-anchor="middle">0.02 dB</text><text x="200" y="190" font-size="11" fill="#9a9aa6" text-anchor="middle">strip · clean · cleave · fusion splice · sleeve</text>`),
    cut: () => svg(wall + `<line x1="40" y1="128" x2="360" y2="128" stroke="#111" stroke-width="5"/><g class="a-snip" transform="translate(190 128)"><circle cx="-14" cy="22" r="9" fill="none" stroke="#ff453a" stroke-width="4"/><circle cx="14" cy="22" r="9" fill="none" stroke="#ff453a" stroke-width="4"/><line x1="-8" y1="14" x2="10" y2="-22" stroke="#ddd" stroke-width="4"/><line x1="8" y1="14" x2="-10" y2="-22" stroke="#ddd" stroke-width="4"/></g><text x="200" y="200" font-size="12" fill="#9a9aa6" text-anchor="middle">hold to remove · Z undo</text>`),
    pole: () => svg(ground + pole(200, 210, 190) + person(222, 196, 'a-bob') + `<text x="300" y="80" font-size="12" fill="#9a9aa6">W / S climb</text><text x="300" y="100" font-size="12" fill="#9a9aa6">A / D round</text><text x="300" y="120" font-size="12" fill="#9a9aa6">G kit · X down</text>`),
    polekit: () => svg(ground + pole(200, 210, 190) + `<g class="a-pop"><rect x="186" y="70" width="28" height="4" fill="#c9cdd2"/><rect x="186" y="100" width="28" height="4" fill="#c9cdd2"/><rect x="212" y="60" width="34" height="56" rx="14" fill="#1b1b1e"/><g fill="#30d158">${[0, 1, 2, 3].map((i) => `<circle cx="${218 + i * 8}" cy="112" r="3"/>`).join('')}</g></g>` + person(178, 150)),
    span: () => svg(ground + pole(80, 210, 170) + pole(320, 210, 170) + `<path d="M85 46 Q 200 90 315 46" fill="none" stroke="#111" stroke-width="4" class="a-draw"/><circle cx="85" cy="46" r="5" fill="#c9cdd2"/><circle cx="315" cy="46" r="5" fill="#c9cdd2"/><text x="200" y="140" font-size="11" fill="#9a9aa6" text-anchor="middle">aim near a pole — it clamps on (ring head near the top)</text>`),
    ladder: () => svg(wall + ground + `<g transform="translate(240 210) rotate(16)"><g><rect x="-22" y="-120" width="5" height="120" fill="#c9cdd2"/><rect x="17" y="-120" width="5" height="120" fill="#c9cdd2"/>${Array.from({ length: 8 }, (_, i) => `<rect x="-17" y="${-12 - i * 14}" width="34" height="3" fill="#aab"/>`).join('')}</g><g class="a-extend"><rect x="-19" y="-150" width="4" height="110" fill="#e0e3e7"/><rect x="15" y="-150" width="4" height="110" fill="#e0e3e7"/>${Array.from({ length: 7 }, (_, i) => `<rect x="-15" y="${-52 - i * 14}" width="30" height="3" fill="#bcc"/>`).join('')}</g></g><text x="120" y="80" font-size="12" fill="#9a9aa6">carry · walk up · scroll</text>`),
    drum: () => svg(ground + `<g transform="translate(110 150)"><circle r="48" fill="#c8a06d"/><circle r="34" fill="#151517" class="a-spin"/><g class="a-spin"><line x1="-34" y1="0" x2="34" y2="0" stroke="#333" stroke-width="3"/><line x1="0" y1="-34" x2="0" y2="34" stroke="#333" stroke-width="3"/></g><path d="M-30 58 L0 0 L30 58" fill="none" stroke="#9aa" stroke-width="5"/></g><path d="M140 120 C 170 205, 240 210, 320 196" fill="none" stroke="#111" stroke-width="4" class="a-draw"/>` + person(330, 210)),
    path: () => {
      const nodes = [[40, 'Cabinet'], [115, 'Splice'], [190, 'CBT'], [265, 'CSP'], [340, 'ONT']];
      return svg(`<path id="fp" d="M40 125 H340" fill="none" stroke="#ffd60a" stroke-width="4"/>` + nodes.map(([x, t], i) => `<rect x="${x - 26}" y="100" width="52" height="50" rx="10" fill="${i === 0 ? '#2f5a3c' : i === 4 ? '#efefec' : '#1b1b1e'}" stroke="#3b3b4a"/><text x="${x}" y="172" font-size="11" fill="#cfcfd8" text-anchor="middle">${t}</text>`).join('') +
        `<circle r="7" fill="#fff" style="offset-path: path('M40 125 H340')" class="a-travel"/>`);
    },
    lan: () => svg(wall + ont(150, 70) + `<path d="M205 126 C 205 170, 250 170, 250 196" fill="none" stroke="#1f6fff" stroke-width="5" class="a-draw"/><rect x="215" y="196" width="80" height="16" rx="5" fill="#2a2a35"/><circle cx="230" cy="204" r="3" fill="#30d158" class="a-blink"/><text x="80" y="230" font-size="11" fill="#9a9aa6">CAT6 from the ONT's LAN port to a router</text>`),
    provision: () => svg(`<rect x="100" y="30" width="200" height="190" rx="14" fill="#1b1b24" stroke="#33333f"/><text x="116" y="58" font-size="13" font-weight="700" fill="#fff">Internet service</text>` +
      [['OPS Fibre · Fibre 900', '#0a84ff'], ['Velocity · Superfast 80', '#ff375f'], ['Lumen · Gigabit 1000', '#30d158']].map(([t, c], i) => `<rect x="114" y="${74 + i * 34}" width="172" height="28" rx="8" fill="${i === 0 ? '#0a84ff33' : '#24242f'}" stroke="${i === 0 ? '#0a84ff' : 'none'}"/><rect x="124" y="${84 + i * 34}" width="8" height="8" rx="2" fill="${c}"/><text x="140" y="${92 + i * 34}" font-size="10.5" fill="#e8e8ee">${t}</text>`).join('') + `<rect x="114" y="182" width="172" height="26" rx="8" fill="#0a84ff" class="a-pulse"/><text x="200" y="199" font-size="11" font-weight="700" fill="#fff" text-anchor="middle">Save line</text>`),
    ontleds: () => svg(`<g transform="translate(200 100) scale(2) translate(-55 -28)">${ont(0, 0, ['g', 'b', '', 'g', 'b'])}</g>` + `<text x="200" y="200" font-size="12" fill="#9a9aa6" text-anchor="middle">walk up to an ONT — the lights pop up</text>`),
    cones: () => svg(ground + [80, 140, 200].map((x) => `<path d="M${x - 16} 210 L${x} 160 L${x + 16} 210 Z" fill="#f06014"/><rect x="${x - 11}" y="184" width="22" height="7" fill="#fff"/><rect x="${x - 20}" y="206" width="40" height="5" fill="#111"/>`).join('') +
      `<g transform="translate(240 140)"><rect width="140" height="10" fill="url(#rw)"/><rect y="20" width="140" height="30" fill="#fff"/><text x="70" y="40" font-size="10" font-weight="800" text-anchor="middle" fill="#111">FIBRE WORKS</text><rect y="56" width="140" height="10" fill="url(#rw)"/><rect x="2" y="0" width="4" height="70" fill="#999"/><rect x="134" y="0" width="4" height="70" fill="#999"/></g><defs><pattern id="rw" width="28" height="10" patternUnits="userSpaceOnUse"><rect width="14" height="10" fill="#c81c20"/><rect x="14" width="14" height="10" fill="#fff"/></pattern></defs>`),
    tlight: () => svg(ground + `<g transform="translate(110 40)"><rect x="-4" y="70" width="8" height="100" fill="#999"/><rect x="-24" y="0" width="48" height="96" rx="6" fill="#111" stroke="#fad61e" stroke-width="3"/><circle cy="18" r="11" fill="#ff453a" class="tl-r"/><circle cy="48" r="11" fill="#ff9f0a" class="tl-a"/><circle cy="78" r="11" fill="#30d158" class="tl-g"/></g>` +
      `<g transform="translate(220 70)"><rect width="150" height="104" rx="4" fill="#fad61e" stroke="#c81c20" stroke-width="6"/><text x="75" y="34" font-size="15" font-weight="900" text-anchor="middle" fill="#111">FIBRE WORKS</text><text x="75" y="54" font-size="11" font-weight="800" text-anchor="middle" fill="#111">IN PROGRESS</text><text x="75" y="76" font-size="10" font-weight="700" text-anchor="middle" fill="#111">Mon 06/10 – Fri 10/10</text><text x="75" y="92" font-size="10" font-weight="700" text-anchor="middle" fill="#111">08:00 – 18:00</text></g>`),
  };

  // ------------------------------------------------------------------ content
  const CHAPTERS = [
    { id: 'mobile', icon: '<svg viewBox="0 0 24 24"><rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/></svg>', color: '#0a84ff', title: 'OPS Mobile', sub: 'Plans, signal, Wi-Fi', slides: [
      { art: 'esim', h: 'Get an eSIM plan', p: 'Texts, calls and mobile data need an OPS Mobile plan.', steps: ['Open the <b>OPS Mobile</b> app on your phone, or the OPS Mobile website.', 'Pick a plan and pay.', 'Your eSIM arrives by text — tap it to activate. Your plan and usage show in the app.'] },
      { art: 'nosignal', h: 'No signal? Only emergency calls', p: 'Coverage comes from real cell towers in the city. Away from them you have <b>no service</b>.', steps: ['Texts, normal calls and apps that need data stop working.', 'Calls to emergency numbers always go through.', 'Calls drop if either side loses signal.'], tip: 'Wi-Fi keeps your apps working even with no signal.' },
      { art: 'wifi', h: 'Join Wi-Fi', p: 'Buildings can have Wi-Fi access points. On Wi-Fi your apps work and don’t use plan data.', steps: ['Open <b>Settings › Wi-Fi</b> on the phone.', 'Tap a network. Locked ones ask for the password once — it’s remembered.', 'Some networks are for certain jobs only.'] },
      { art: 'store', h: 'The OPS Mobile app & website', p: 'Manage your line, top up credit, change plan and read messages from OPS Mobile — on the phone or on the website.' },
    ] },
    { id: 'towers', icon: '<svg viewBox="0 0 24 24"><path d="M12 13v8M8 21h8"/><circle cx="12" cy="11" r="2"/><path d="M7.5 6.5a6.4 6.4 0 0 0 0 9M16.5 6.5a6.4 6.4 0 0 1 0 9M4.6 3.6a10.5 10.5 0 0 0 0 14.8M19.4 3.6a10.5 10.5 0 0 1 0 14.8"/></svg>', color: '#30d158', title: 'Towers & Wi-Fi', sub: 'Admins: build the network', slides: [
      { art: 'menu', h: 'The /towers menu', p: `Type <code>/towers</code>. The menu shows your signal here and everything you can build. It stays open until ${K('Esc')}.` },
      { art: 'aim', h: 'Place a tower or access point', steps: ['Choose <b>Place a cell tower</b> or <b>Wi-Fi access point</b> and fill in name, range and model.', `Aim where it goes — a see-through preview follows your view. ${K('Scroll')} rotates, ${K('↑')} ${K('↓')} sets height.`, `${K('LMB')} or ${K('Enter')} places it.`] },
      { art: 'coverage', h: 'Passwords, bulk & overlay', steps: ['Edit an access point to set a password or limit it to jobs.', '<b>Bulk actions</b> switches off or deletes many towers at once.', '<b>Coverage overlay</b> shows range circles on the map.'] },
      { art: 'map', h: 'The website map', p: 'Admins see every tower and player live on the store website’s <b>Tower map</b>. Drag a tower to move it, click the map to add one.' },
    ] },
    { id: 'cabling', icon: '<svg viewBox="0 0 24 24"><path d="M9 2v5M15 2v5M6 7h12v4a6 6 0 0 1-12 0zM12 17v5"/></svg>', color: '#ff9f0a', title: 'Cabling', sub: 'CAT6, fibre, trunking', slides: [
      { art: 'box', h: 'Start with a cable box', p: `Type <code>/cable</code>. Every run comes out of a box.`, steps: ['<b>Place a cable box</b>: CAT6 (305 m), black fibre, yellow fibre or a drop cable drum.', 'Stand next to it and choose <b>Pull cable from the nearest box</b>.'] },
      { art: 'route', h: 'Pull and route the cable', steps: [`${K('LMB')} fixes the cable to the floor, wall or ceiling where you aim.`, `Hold ${K('Shift')} for a dead-straight line. Small height changes snap level.`, `Aim at a router, ONT or other kit and press ${K('Enter')} to connect.`, `${K('Backspace')} undoes the last point.`] },
      { art: 'rj45', h: 'Terminate CAT6', p: 'Strip, untwist, arrange the eight wires in order, trim and crimp the RJ45.', steps: ['T568B order: white-orange, orange, white-green, blue, white-blue, green, white-brown, brown.', 'Cut the cable off the box first, then terminate each end next to its device.'] },
      { art: 'trunk', h: 'Trunking', p: 'White, black or blue trunking. Aim at it while pulling cable and the cable runs inside, out of sight.' },
      { art: 'splice', h: 'Fibre', p: 'Fibre is pulled the same way but spliced instead of crimped.', steps: ['Strip the sheath and coating, clean, cleave.', 'Fusion splice and slide on the protection sleeve.', 'Black fibre for outside, yellow for inside.'] },
      { art: 'cut', h: 'Cut, move, remove, undo', steps: ['<b>Cut a cable</b>: aim anywhere along it — two pieces with bare ends.', '<b>Move</b>: aim at a cable to reshape it (drag points, E adds a bend) or at a box to carry it.', `<b>Remove</b>: aim, it outlines red, hold ${K('LMB')}. ${K('Z')} puts it back.`] },
    ] },
    { id: 'poles', icon: '<svg viewBox="0 0 24 24"><path d="M8 2l-2 20M16 2l2 20M7.5 7h9M7 12h10M6.5 17h11"/></svg>', color: '#a2845e', title: 'Poles & ladders', sub: 'Climb, fit kit, drop cable', slides: [
      { art: 'pole', h: 'Climb a pole', p: 'Placed poles (7, 10, 13 m) and the map’s telegraph poles can be climbed.', steps: [`Stand at the base and press ${K('E')}.`, `${K('W')} ${K('S')} climb, ${K('A')} ${K('D')} move round. Stop and your feet settle on the steps.`, `${K('X')} climbs down.`] },
      { art: 'polekit', h: 'Fit equipment on the pole', p: `On the pole press ${K('G')}: fit a CBT, copper DP or splice enclosure at your height on your side. It’s strapped on with steel bands.` },
      { art: 'span', h: 'Clamp cable to poles', p: 'While pulling cable, aim near a pole — even far up — and the cable clamps on. Near the top it goes on the ring head. Spans between poles hang with a sag.', tip: 'Fit a <b>house pole</b> on the building (Telecom equipment) to take the drop from the pole to the house.' },
      { art: 'ladder', h: 'Ladders', steps: ['<code>/ladder</code> — 6.9 m or 13 m. You carry it in front of you.', 'Walk up to a wall or pole: it leans on it. Scroll to extend (Shift fine).', `At the foot: ${K('E')} climb, ${K('H')} extend, ${K('G')} move or take down.`, `At the top of a ladder on a pole, ${K('F')} steps onto the pole (and back).`] },
      { art: 'drum', h: 'Drop cable drum', p: 'Put down a drop cable drum and pull dropwire from it — the reel turns and the slack lies on the ground from the last fixed point to your hand.' },
    ] },
    { id: 'internet', icon: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5"/><path d="M2.5 12h19M12 2.5a14 14 0 0 1 0 19M12 2.5a14 14 0 0 0 0 19"/></svg>', color: '#8e7dff', title: 'Internet service', sub: 'Fibre to the home', slides: [
      { art: 'path', h: 'The fibre path', p: 'Light comes from a street cabinet (the provider’s exchange) and travels over spliced fibre to the home.', steps: ['Cabinet → splice enclosure → CBT on the pole → CSP on the wall → ONT inside.', 'You can skip the middle boxes and go cabinet → ONT.'] },
      { art: 'splice', h: 'Splice every hop', steps: ['Place a fibre box next to where each run starts and pull to the next piece of kit.', `Aim at it and press ${K('Enter')} to connect, then splice the end.`, 'Cut the run off the box and splice the start next to the kit it starts at.'] },
      { art: 'lan', h: 'Plug in a router', p: 'Run CAT6 from the ONT to a router (OPS Gateway, EdgeLink, HomeRouter or Mesh placed as a Wi-Fi access point) and terminate both ends.' },
      { art: 'provision', h: 'Provision the line', steps: ['Open the ONT in <b>Telecom equipment</b> → <b>Internet service</b>.', 'Pick a provider and plan, add a customer or address.', 'Admins can do the same on the store website under <b>Internet service</b>.'] },
      { art: 'ontleds', h: 'ONT lights', legend: [['POWER', 'g', 'On'], ['PON', 'g blink', 'Blinks while it registers, then solid'], ['LOS', 'r', 'Red: no light — a splice is missing'], ['LAN', 'g fast', 'Router plugged in (flickers with traffic)'], ['INTERNET', 'g blink', 'Blinks while connecting, solid when up, red when suspended']] },
    ] },
    { id: 'roadworks', icon: '<svg viewBox="0 0 24 24"><path d="M12 3l9 17H3z"/><path d="M12 9v5M12 17h.01"/></svg>', color: '#ff375f', title: 'Road safety', sub: 'Set out street works', slides: [
      { art: 'cones', h: 'Set out the works', p: 'Network cabling → <b>Road safety equipment</b>: cones, “Fibre works in progress” and “Stay back” barriers, and cordon tape. Aim and place each one.' },
      { art: 'tlight', h: 'Signs & traffic lights', steps: ['<b>Works signs</b>: type the heading, dates, times and a footer — it’s drawn on the sign.', '<b>Traffic lights</b>: place two, set one to side A and the other to B. One is green while the other is red.', 'Pick it all up from the nearby list when the job’s done.'] },
    ] },
  ];

  // ------------------------------------------------------------------ state + render
  const el = (id) => document.getElementById(id);
  let state = { chapter: null, slide: 0, done: {} };

  const save = () => post('save', state);
  const total = () => CHAPTERS.reduce((n, c) => n + c.slides.length, 0);

  function renderHome() {
    state.chapter = null;
    el('title').textContent = 'OPS Guide';
    el('subtitle').textContent = 'Everything network & mobile';
    el('back-home').classList.add('invisible');
    el('nav').classList.add('hidden');
    const doneCount = Object.keys(state.done || {}).length;
    el('bar').style.width = `${Math.round((doneCount / CHAPTERS.length) * 100)}%`;
    el('view').innerHTML = `<p class="intro">Pick a chapter. Each one is a few short, animated steps. ${doneCount ? `You’ve finished <b>${doneCount}</b> of ${CHAPTERS.length}.` : ''}</p>` +
      CHAPTERS.map((c) => `<button class="chapter" data-ch="${c.id}"><span class="ic" style="--c:${c.color}">${c.icon}</span><span><b>${c.title}</b><small>${c.sub} · ${c.slides.length} steps</small></span><span class="state ${state.done[c.id] ? 'done' : state.last === c.id ? 'part' : ''}">${state.done[c.id] ? '✓' : ''}</span></button>`).join('');
    el('view').querySelectorAll('[data-ch]').forEach((b) => b.addEventListener('click', () => openChapter(b.dataset.ch, 0)));
    el('view').className = 'enter';
    save();
  }

  function openChapter(id, slide, dir) {
    const c = CHAPTERS.find((x) => x.id === id);
    if (!c) return renderHome();
    state.chapter = id; state.last = id;
    state.slide = Math.max(0, Math.min(slide, c.slides.length - 1));
    const s = c.slides[state.slide];
    el('title').textContent = c.title;
    el('subtitle').textContent = s.h;
    el('back-home').classList.remove('invisible');
    el('nav').classList.remove('hidden');
    el('bar').style.width = `${Math.round(((state.slide + 1) / c.slides.length) * 100)}%`;
    el('count').textContent = `${state.slide + 1} / ${c.slides.length}`;
    el('prev').disabled = state.slide === 0;
    el('next').textContent = state.slide === c.slides.length - 1 ? 'Done' : 'Next';
    const steps = s.steps ? `<ol class="steps">${s.steps.map((t) => `<li>${t}</li>`).join('')}</ol>` : '';
    const legend = s.legend ? `<div class="legend">${s.legend.map(([n, d, t]) => `<div><b><span class="dot ${d.split(' ').map((x) => x).join(' ')}"></span>${n}</b><span>${t}</span></div>`).join('')}</div>` : '';
    el('view').innerHTML = `<div class="slide"><div class="art">${ART[s.art] ? ART[s.art]() : ''}</div><h2>${s.h}</h2>${s.p ? `<p>${s.p}</p>` : ''}${steps}${legend}${s.tip ? `<div class="tip"><svg viewBox="0 0 24 24" class="tip-ic"><path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9V16h7v-2.1A6 6 0 0 0 12 3z"/></svg><span>${s.tip}</span></div>` : ''}</div>`;
    el('view').className = 'enter' + (dir === -1 ? ' back' : '');
    el('view').scrollTop = 0;
    save();
  }

  function next() {
    if (!state.chapter) return;
    const c = CHAPTERS.find((x) => x.id === state.chapter);
    if (state.slide < c.slides.length - 1) return openChapter(c.id, state.slide + 1, 1);
    state.done[c.id] = true;
    const i = CHAPTERS.indexOf(c);
    if (i < CHAPTERS.length - 1) openChapter(CHAPTERS[i + 1].id, 0, 1); else renderHome();
  }
  function prev() { if (state.chapter && state.slide > 0) openChapter(state.chapter, state.slide - 1, -1); }
  function close() { el('guide').classList.add('hidden'); post('close'); }

  el('next').addEventListener('click', next);
  el('prev').addEventListener('click', prev);
  el('back-home').addEventListener('click', renderHome);
  el('close').addEventListener('click', close);
  document.addEventListener('keydown', (e) => {
    if (el('guide').classList.contains('hidden')) return;
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowRight' || e.key === 'Enter') next();
    else if (e.key === 'ArrowLeft') prev();
  });

  window.addEventListener('message', (e) => {
    const m = e.data || {};
    if (m.action === 'open') {
      state = Object.assign({ chapter: null, slide: 0, done: {} }, m.pos || {});
      state.done = state.done || {};
      el('guide').classList.remove('hidden');
      if (state.chapter) openChapter(state.chapter, state.slide); else renderHome();
    } else if (m.action === 'close') {
      el('guide').classList.add('hidden');
    }
  });

  window.OPSGuide = { CHAPTERS, total, openChapter, renderHome };
})();
