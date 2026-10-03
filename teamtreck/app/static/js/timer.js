document.addEventListener('DOMContentLoaded', () => {
    const display = document.getElementById('timer-display');
    if (!display) return;

    let seconds = parseInt(display.dataset.seconds, 10) || 0;
    const status = display.dataset.status;

    function format(s) {
        const h = String(Math.floor(s / 3600)).padStart(2, '0');
        const m = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
        const sec = String(s % 60).padStart(2, '0');
        return `${h}:${m}:${sec}`;
    }

    if (status === 'running') {
        setInterval(() => {
            seconds += 1;
            display.textContent = format(seconds);
        }, 1000);
    }
});
