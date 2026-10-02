(function () {
  const sidebar = document.getElementById("sidebar");
  const backdrop = document.getElementById("sidebar-backdrop");
  const openBtn = document.getElementById("nav-toggle");
  const closeBtn = document.getElementById("nav-close");

  if (!sidebar || !backdrop || !openBtn) return;

  function openNav() {
    sidebar.classList.remove("-translate-x-full");
    sidebar.classList.add("vm-open");
    backdrop.classList.remove("hidden");
    openBtn.setAttribute("aria-expanded", "true");
  }

  function closeNav() {
    sidebar.classList.add("-translate-x-full");
    sidebar.classList.remove("vm-open");
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

// --- Display mode (desktop / tablet / mobile) ---
// Lets someone force a layout for this browser regardless of actual screen
// size — offered as a one-time splash on first visit, and reachable any
// time after via the "Display" button in the topbar / sidebar.
(function () {
  const STORAGE_KEY = "schedulerViewMode";
  const modal = document.getElementById("view-mode-modal");
  if (!modal) return;

  const triggers = [
    document.getElementById("view-mode-trigger"),
    document.getElementById("view-mode-trigger-desktop"),
  ].filter(Boolean);
  const dismissBtn = document.getElementById("view-mode-dismiss");
  const options = modal.querySelectorAll(".view-mode-option");

  function currentChoice() {
    try {
      return localStorage.getItem(STORAGE_KEY);
    } catch (e) {
      return null;
    }
  }

  function applyChoice(value) {
    if (value && value !== "auto") {
      document.documentElement.setAttribute("data-view", value);
    } else {
      document.documentElement.removeAttribute("data-view");
    }
  }

  function saveChoice(value) {
    try {
      localStorage.setItem(STORAGE_KEY, value);
    } catch (e) {}
    applyChoice(value);
  }

  function openModal() {
    modal.classList.remove("hidden");
    modal.classList.add("flex");
  }

  function closeModal() {
    modal.classList.add("hidden");
    modal.classList.remove("flex");
  }

  options.forEach((btn) => {
    btn.addEventListener("click", () => {
      saveChoice(btn.dataset.viewChoice);
      closeModal();
    });
  });

  dismissBtn && dismissBtn.addEventListener("click", () => {
    try {
      localStorage.setItem(STORAGE_KEY, "auto");
    } catch (e) {}
    closeModal();
  });

  triggers.forEach((btn) => btn.addEventListener("click", openModal));

  modal.addEventListener("click", (e) => {
    if (e.target === modal) closeModal();
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") closeModal();
  });

  // First-ever visit: nothing saved yet — show the splash.
  if (currentChoice() === null) {
    openModal();
  }
})();
