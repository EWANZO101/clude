// Searchable currency dropdown. Works on any element with class
// "currency-select" containing a text input (.cs-input), a hidden input
// (.cs-hidden) that carries the ISO code for form submission, and a
// results container (.cs-results).
(function () {
  function initCurrencySelect(root) {
    const input = root.querySelector(".cs-input");
    const hidden = root.querySelector(".cs-hidden");
    const results = root.querySelector(".cs-results");
    const display = root.querySelector(".cs-display");

    function renderResults(items) {
      results.innerHTML = "";
      if (!items.length) {
        results.innerHTML = '<div class="px-3 py-2 text-xs text-muted">No matching currency</div>';
      }
      items.forEach((c) => {
        const row = document.createElement("button");
        row.type = "button";
        row.className = "w-full text-left px-3.5 py-2.5 text-sm hover:bg-white/[0.04] flex items-center gap-2.5 transition rounded-lg";
        row.innerHTML = `<span>${c.flag}</span><span class="num text-gold w-12">${c.code}</span><span class="text-parchment flex-1">${c.name}</span><span class="num text-muted">${c.symbol}</span>`;
        row.addEventListener("click", () => {
          hidden.value = c.code;
          input.value = `${c.code} — ${c.name}`;
          if (display) display.textContent = `${c.flag} ${c.code} — ${c.name} (${c.symbol})`;
          results.classList.add("hidden");
          root.dispatchEvent(new CustomEvent("currency-change", { detail: c }));
        });
        results.appendChild(row);
      });
      results.classList.remove("hidden");
    }

    async function search(q) {
      const res = await fetch(`/api/currencies?q=${encodeURIComponent(q)}`);
      const data = await res.json();
      renderResults(data);
    }

    input.addEventListener("focus", () => search(""));
    input.addEventListener("input", () => search(input.value));
    document.addEventListener("click", (e) => {
      if (!root.contains(e.target)) results.classList.add("hidden");
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".currency-select").forEach(initCurrencySelect);
  });
})();
