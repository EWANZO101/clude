const frame = document.getElementById('frame');
const screenEmpty = document.getElementById('screenEmpty');
const reloadBtn = document.getElementById('reload');

function loadApp() {
    screenEmpty.hidden = false;
    screenEmpty.innerText = 'Loading…';

    fetchNui('xonsight:getConfig')
        .then((cfg) => {
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

onSettingsChange((settings) => {
    document.getElementById('app').dataset.theme = settings.display.theme;
});

getSettings().then((settings) => {
    document.getElementById('app').dataset.theme = settings.display.theme;
    loadApp();
});
