// Routes NUI messages from client/main.lua to the theme frame of the brand being opened.
// Add a folder to web/themes/ and its name here to add a new store UI.
const THEMES = ['supermarket247', 'ltd', 'youtool', 'digitalden'];

const frames = {};
let activeTheme = null;

function createFrame(theme) {
    const frame = document.createElement('iframe');
    frame.className = 'theme-frame';
    frame.src = `themes/${theme}/index.html`;
    frame.setAttribute('allowtransparency', 'true');

    const entry = { frame, ready: false, queue: [] };

    frame.addEventListener('load', () => {
        entry.ready = true;
        entry.queue.forEach((message) => frame.contentWindow.postMessage(message, '*'));
        entry.queue = [];
    });

    document.body.appendChild(frame);
    frames[theme] = entry;
}

function send(theme, message) {
    const entry = frames[theme];
    if (!entry) return;

    if (entry.ready) {
        entry.frame.contentWindow.postMessage(message, '*');
    } else {
        entry.queue.push(message);
    }
}

function show(theme) {
    for (const [name, entry] of Object.entries(frames)) {
        entry.frame.classList.toggle('active', name === theme);
    }

    activeTheme = theme;

    const entry = frames[theme];
    if (entry) {
        entry.frame.focus();
        if (entry.ready) entry.frame.contentWindow.focus();
    }
}

function hideAll() {
    for (const entry of Object.values(frames)) {
        entry.frame.classList.remove('active');
    }
    activeTheme = null;
}

THEMES.forEach(createFrame);

window.addEventListener('message', (event) => {
    // Ignore anything the theme frames post themselves.
    if (Object.values(frames).some((entry) => event.source === entry.frame.contentWindow)) return;

    const message = event.data || {};

    if (message.action === 'open') {
        const theme = message.data && frames[message.data.theme] ? message.data.theme : THEMES[0];
        show(theme);
        send(theme, message);
        return;
    }

    if (message.action === 'close') {
        if (activeTheme) send(activeTheme, message);
        hideAll();
        return;
    }

    if (activeTheme) send(activeTheme, message);
});

// Browser preview (outside FiveM): open index.html?theme=youtool to look at one theme.
if (typeof GetParentResourceName !== 'function') {
    const requested = new URLSearchParams(location.search).get('theme');
    show(frames[requested] ? requested : THEMES[0]);
}
