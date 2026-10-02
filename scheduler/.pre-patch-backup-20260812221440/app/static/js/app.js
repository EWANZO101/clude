(function () {
  const sidebar = document.getElementById("sidebar");
  const backdrop = document.getElementById("sidebar-backdrop");
  const openBtn = document.getElementById("nav-toggle");
  const closeBtn = document.getElementById("nav-close");

  if (!sidebar || !backdrop || !openBtn) return;

  function openNav() {
    sidebar.classList.remove("-translate-x-full");
    backdrop.classList.remove("hidden");
    openBtn.setAttribute("aria-expanded", "true");
  }

  function closeNav() {
    sidebar.classList.add("-translate-x-full");
    backdrop.classList.add("hidden");
    openBtn.setAttribute("aria-expanded", "false");
  }

  openBtn.addEventListener("click", openNav);
  closeBtn && closeBtn.addEventListener("click", closeNav);
  backdrop.addEventListener("click", closeNav);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeNav();
  });
})();
