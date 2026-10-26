// Shared Xon Sight phone-app UI (viewer + optional in-phone capture), used by every phone bootstrap in
// ../lbphone, ../gksphone and ../movement. Nothing in this file talks to a phone's own injected globals
// directly - each bootstrap defines `window.PhoneBridge` first (see those folders' index.html) and this file
// only calls through that, so the same UI runs unchanged on every supported phone.
//
// window.PhoneBridge (all optional except none are required - missing pieces just degrade gracefully):
//   getTheme()        -> Promise<'light'|'dark'>
//   onThemeChange(cb)  -- cb(theme) whenever the phone's theme changes
//   captureVideo(opts) -> Promise<url|null>  -- records with the phone's own camera; omit to hide the button
//   setStatusBarColor(cssColor)

function fetchNui(name, data) {
    return fetch(location.origin + '/' + name, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data || {}),
    }).then((resp) => resp.json());
}

const Bridge = window.PhoneBridge || {};

const frame = document.getElementById('frame');
const screenEmpty = document.getElementById('screenEmpty');
const reloadBtn = document.getElementById('reload');
const captureBtn = document.getElementById('capture');
const captureOverlay = document.getElementById('captureOverlay');
const captureCaption = document.getElementById('captureCaption');
const captureStart = document.getElementById('captureStart');
const captureCancel = document.getElementById('captureCancel');
const captureStatus = document.getElementById('captureStatus');

function setTheme(theme) {
    document.getElementById('app').dataset.theme = theme;

    const bg = theme === 'dark' ? '#0c0c0e' : '#ffffff';

    if (typeof Bridge.setStatusBarColor === 'function') {
        Bridge.setStatusBarColor(bg);
    }

    // Sky Phone's status-bar contract: a plain postMessage, ignored harmlessly by every other phone.
    window.parent.postMessage({
        type: 'sky-phone-app:status-bar-background',
        appId: new URLSearchParams(location.search).get('skyPhoneAppId'),
        protocolVersion: 1,
        background: bg,
    }, '*');
}

function loadApp() {
    screenEmpty.hidden = false;
    screenEmpty.innerText = 'Loading…';

    fetchNui('xonsight:getConfig')
        .then((cfg) => {
            const canCapture = !!(cfg && cfg.allowCapture && typeof Bridge.captureVideo === 'function');
            captureBtn.hidden = !canCapture;

            if (!cfg || !cfg.siteUrl) {
                screenEmpty.innerText = 'Xon Sight is not configured - set ServerConfig.XonSight.Url in opslabs-bodycam/config_server.lua';
                return;
            }
            frame.src = cfg.siteUrl + (cfg.startPath || '/dashboard');
        })
        .catch(() => {
            screenEmpty.innerText = 'Could not reach Xon Sight';
        });
}

frame.addEventListener('load', () => {
    if (frame.src !== 'about:blank') {
        screenEmpty.hidden = true;
    }
});

reloadBtn.onclick = () => loadApp();

// Records video with the phone's own camera and submits it straight to Xon Sight's evidence webhook - a
// second, independent way to get evidence into the portal that doesn't involve the bodycam itself.
function openCapture() {
    captureCaption.value = '';
    captureStatus.hidden = true;
    captureStatus.className = 'capture-status';
    captureStart.disabled = false;
    captureStart.innerText = 'Record';
    captureOverlay.classList.remove('hidden');
}

function closeCapture() {
    captureOverlay.classList.add('hidden');
}

captureBtn.onclick = () => openCapture();
captureCancel.onclick = () => closeCapture();

// Reports editable-field focus to whichever phone is hosting us (GKSPHONE's InputChange, Sky Phone's
// SetPhoneGameInputEnabled, ...) so gameplay input stops while the player is typing the caption. A no-op on
// phones without that NUI callback wired up (see each module's client.lua).
captureCaption.addEventListener('focus', () => fetchNui('xonsight:inputFocus', { focused: true }));
captureCaption.addEventListener('blur', () => fetchNui('xonsight:inputFocus', { focused: false }));

captureStart.onclick = () => {
    if (typeof Bridge.captureVideo !== 'function') return;

    captureStart.disabled = true;
    captureStart.innerText = 'Recording…';

    Bridge.captureVideo({
        default: { type: 'Video', flash: false, camera: 'rear' },
        permissions: { toggleFlash: true, flipCamera: true, takePhoto: false, takeVideo: true, takeLandscapePhoto: false },
    }).then((url) => {
        if (!url) {
            captureStart.disabled = false;
            captureStart.innerText = 'Record';
            return;
        }

        captureStart.innerText = 'Submitting…';
        fetchNui('xonsight:submitEvidence', {
            videoUrl: url,
            caption: captureCaption.value || '',
        }).then((result) => {
            captureStatus.hidden = false;
            captureStatus.className = 'capture-status ' + (result && result.ok ? 'ok' : 'err');
            captureStatus.innerText = (result && result.message) || (result && result.ok ? 'Submitted' : 'Failed');
            captureStart.disabled = false;
            captureStart.innerText = 'Record';

            if (result && result.ok) {
                setTimeout(closeCapture, 1200);
            }
        });
    });
};

function init() {
    document.body.style.visibility = 'visible';

    if (typeof Bridge.onThemeChange === 'function') {
        Bridge.onThemeChange((theme) => setTheme(theme || 'dark'));
    }

    if (typeof Bridge.getTheme === 'function') {
        Bridge.getTheme().then((theme) => setTheme(theme || 'dark')).then(loadApp, loadApp);
    } else {
        setTheme('dark');
        loadApp();
    }
}

if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
} else {
    init();
}
