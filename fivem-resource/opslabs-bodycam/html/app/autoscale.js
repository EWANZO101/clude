// Universal screen auto-fit, shared by every phone bootstrap (lbphone/gksphone/movement, and Sky Phone
// through its lb-phone/17mov_Phone compatibility aliases). The app's CSS is rem/em-based; instead of asking
// each phone's own API for its current zoom/scale setting (LB, GKSPHONE and 17Movement each expose that
// differently, or not at all), this measures the iframe's own rendered pixel box and rescales the root
// font-size to fit it - correct for any phone, any screen resolution, any host zoom/scale, with no per-phone
// code. Must run before body becomes visible (see script.js's init()).

(function () {
    var BASE_WIDTH = 380;
    var BASE_HEIGHT = 760;
    var MIN_SCALE = 0.5;
    var MAX_SCALE = 2.5;

    function fit() {
        var root = document.documentElement;
        var width = root.clientWidth || BASE_WIDTH;
        var height = root.clientHeight || BASE_HEIGHT;

        var scale = Math.min(width / BASE_WIDTH, height / BASE_HEIGHT);
        scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, scale));

        root.style.fontSize = (16 * scale).toFixed(2) + 'px';
    }

    if (window.ResizeObserver) {
        new ResizeObserver(fit).observe(document.documentElement);
    }
    window.addEventListener('resize', fit);

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', fit);
    } else {
        fit();
    }
})();
