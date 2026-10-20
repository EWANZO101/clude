const frame = document.getElementById('frame');
const screenEmpty = document.getElementById('screenEmpty');
const reloadBtn = document.getElementById('reload');
const captureBtn = document.getElementById('capture');
const captureOverlay = document.getElementById('captureOverlay');
const captureCaption = document.getElementById('captureCaption');
const captureStart = document.getElementById('captureStart');
const captureCancel = document.getElementById('captureCancel');
const captureStatus = document.getElementById('captureStatus');

function loadApp() {
    screenEmpty.hidden = false;
    screenEmpty.innerText = 'Loading…';

    fetchNui('xonsight:getConfig')
        .then((cfg) => {
            captureBtn.hidden = !cfg || !cfg.allowCapture;

            if (!cfg || !cfg.siteUrl || cfg.siteUrl.indexOf('YOUR_SITE_HOST') !== -1) {
                screenEmpty.innerText = 'Xon Sight is not configured - set Config.SiteUrl in config.lua';
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

// Records video with LB Phone's own camera and submits it straight to
// Xon Sight's evidence webhook - a second, independent way to get
// evidence into the portal that doesn't involve OPS Phone or any other
// bodycam resource at all.
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

captureStart.onclick = () => {
    captureStart.disabled = true;
    captureStart.innerText = 'Recording…';

    useCamera(
        (url) => {
            if (!url) {
                captureStart.disabled = false;
                captureStart.innerText = 'Record';
                return;
            }

            captureStart.innerText = 'Submitting…';
            fetchNui('xonsight:submitEvidence', {
                videoUrl: url,
                caption: captureCaption.value || '',
            });
        },
        {
            default: { type: 'Video', flash: false, camera: 'rear' },
            permissions: { toggleFlash: true, flipCamera: true, takePhoto: false, takeVideo: true, takeLandscapePhoto: false },
        }
    );
};

window.addEventListener('message', (e) => {
    if (!e.data || e.data.action !== 'submitResult') return;

    captureStatus.hidden = false;
    captureStatus.className = 'capture-status ' + (e.data.ok ? 'ok' : 'err');
    captureStatus.innerText = e.data.message || (e.data.ok ? 'Submitted' : 'Failed');
    captureStart.disabled = false;
    captureStart.innerText = 'Record';

    if (e.data.ok) {
        setTimeout(closeCapture, 1200);
    }
});

onSettingsChange((settings) => {
    document.getElementById('app').dataset.theme = settings.display.theme;
});

getSettings().then((settings) => {
    document.getElementById('app').dataset.theme = settings.display.theme;
    loadApp();
});
