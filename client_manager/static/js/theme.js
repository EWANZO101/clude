(function () {
  const html = document.documentElement;
  const btn = document.getElementById('theme-toggle');
  const iconLight = document.getElementById('theme-icon-light');
  const iconDark = document.getElementById('theme-icon-dark');

  function updateIcons() {
    const isDark = html.classList.contains('dark');
    if (iconLight && iconDark) {
      iconLight.classList.toggle('hidden', isDark);
      iconDark.classList.toggle('hidden', !isDark);
    }
  }

  updateIcons();

  if (btn) {
    btn.addEventListener('click', function () {
      html.classList.toggle('dark');
      localStorage.setItem('theme', html.classList.contains('dark') ? 'dark' : 'light');
      updateIcons();
    });
  }
})();
