const Browse = (function () {
  let opts = {};
  let categories = [];
  let allItems = null;   // lazy-loaded cache for item_grid components with no category filter
  let allTools = null;
  let selectedItem = null;
  let qtyValue = "";

  function apiBase() {
    return opts.preview ? "" : "";
  }

  async function jsonGet(url) {
    const r = await fetch(url);
    if (!r.ok) throw new Error("Request failed: " + url);
    return r.json();
  }

  async function jsonPost(url, body) {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body || {}),
    });
    return r.json();
  }

  function el(tag, className, html) {
    const e = document.createElement(tag);
    if (className) e.className = className;
    if (html !== undefined) e.innerHTML = html;
    return e;
  }

  async function loadLayout() {
    const url = opts.preview
      ? `/kiosk/api/layout?preview_layout_id=${opts.previewLayoutId}`
      : `/kiosk/api/layout`;
    const data = await jsonGet(url);
    return data.components || [];
  }

  async function loadCategories() {
    categories = await jsonGet("/kiosk/api/categories");
    return categories;
  }

  async function loadItems(categoryIds) {
    if (!categoryIds || categoryIds.length === 0) {
      if (!allItems) allItems = await jsonGet("/kiosk/api/items");
      return allItems;
    }
    const lists = await Promise.all(categoryIds.map((id) => jsonGet(`/kiosk/api/categories/${id}/items`)));
    const seen = new Set();
    const merged = [];
    lists.flat().forEach((item) => {
      if (!seen.has(item.id)) { seen.add(item.id); merged.push(item); }
    });
    return merged;
  }

  async function loadTools(categoryIds) {
    if (!categoryIds || categoryIds.length === 0) {
      if (!allTools) allTools = await jsonGet("/kiosk/api/tools");
      return allTools;
    }
    const lists = await Promise.all(categoryIds.map((id) => jsonGet(`/kiosk/api/categories/${id}/tools`)));
    const seen = new Set();
    const merged = [];
    lists.flat().forEach((tool) => {
      if (!seen.has(tool.id)) { seen.add(tool.id); merged.push(tool); }
    });
    return merged;
  }

  // ── Component renderers ────────────────────────────────────────────────

  function renderHeader(section, comp) {
    const s = comp.settings || {};
    const row = el("div", "b-header");
    const left = el("div", "", `
      <div class="b-header-title">${escapeHtml(s.title || "Welcome")}</div>
      ${s.subtitle ? `<div class="b-header-subtitle">${escapeHtml(s.subtitle)}</div>` : ""}
    `);
    row.appendChild(left);
    if (s.show_logout && !opts.preview) {
      const btn = el("button", "b-logout-btn", '<i class="fas fa-right-from-bracket"></i> Log out');
      btn.onclick = doLogout;
      row.appendChild(btn);
    }
    section.appendChild(row);
  }

  function renderScanPanel(section, comp) {
    const s = comp.settings || {};
    const wrap = el("div", "b-scan-panel");
    wrap.innerHTML = `<i class="fas fa-barcode"></i>
      <input class="b-scan-input" type="text" placeholder="${escapeHtml(s.hint || 'Waiting for scan…')}"
             autocomplete="off" autocapitalize="off" spellcheck="false" ${opts.preview ? "disabled" : ""} />`;
    section.appendChild(wrap);
    if (!opts.preview) {
      const input = wrap.querySelector("input");
      input.addEventListener("keydown", async (e) => {
        if (e.key !== "Enter") return;
        const code = input.value.trim().toUpperCase();
        input.value = "";
        if (!code) return;
        const result = await jsonPost("/kiosk/api/scan-code", { code });
        if (result.ok && result.type === "item") {
          openItemModal(result.item);
        }
      });
      setTimeout(() => input.focus(), 200);
    }
  }

  function renderCategoryGrid(section, comp) {
    const s = comp.settings || {};
    if (s.title) section.appendChild(el("div", "b-section-title", escapeHtml(s.title)));
    const ids = s.category_ids && s.category_ids.length ? s.category_ids : categories.map((c) => c.id);
    const shown = categories.filter((c) => ids.includes(c.id));
    const grid = el("div", `b-grid cols-${s.columns || 3}`);
    if (!shown.length) {
      grid.appendChild(el("div", "b-card-meta", "No categories to show yet."));
    }
    shown.forEach((c) => {
      const tile = el("div", "b-cat-tile");
      tile.innerHTML = `
        <i class="${c.icon || 'fa-solid fa-tag'}" style="color:${c.color || '#93c5fd'}"></i>
        <div class="b-cat-name">${escapeHtml(c.name)}</div>
        ${s.show_item_count !== false ? `<div class="b-cat-count">${c.item_count} item${c.item_count === 1 ? "" : "s"}</div>` : ""}
      `;
      tile.onclick = () => showCategoryItems(c);
      grid.appendChild(tile);
    });
    section.appendChild(grid);
  }

  async function showCategoryItems(category) {
    const items = await loadItems([category.id]);
    renderStandaloneItemList(category.name, items);
  }

  function renderStandaloneItemList(title, items) {
    const container = document.getElementById("browseComponents");
    let overlay = document.getElementById("categoryDrilldown");
    if (overlay) overlay.remove();
    overlay = el("div", "b-section", "");
    overlay.id = "categoryDrilldown";
    overlay.appendChild(el("div", "b-section-title", `${escapeHtml(title)} — tap Browse again to go back`));
    const grid = el("div", "b-grid cols-3");
    items.forEach((item) => grid.appendChild(renderItemCard(item, true)));
    overlay.appendChild(grid);
    container.prepend(overlay);
  }

  function renderItemCard(item, showStock, showSku, showLowBadge, tapAction) {
    showStock = showStock !== false;
    const card = el("div", "b-card");
    let badge = "";
    if (showLowBadge !== false) {
      if (item.stock_status === "out_of_stock") badge = '<span class="b-badge b-badge-out">Out of stock</span>';
      else if (item.stock_status === "low_stock") badge = '<span class="b-badge b-badge-low">Low stock</span>';
    }
    card.innerHTML = `
      <div class="b-card-name">${escapeHtml(item.name)}</div>
      ${showSku && item.sku ? `<div class="b-card-meta">SKU ${escapeHtml(item.sku)}</div>` : ""}
      ${showStock ? `<div class="b-card-meta">${escapeHtml(item.display_stock || "")}</div>` : ""}
      ${badge}
    `;
    if (!opts.preview && tapAction !== "view_only") {
      card.onclick = () => openItemModal(item);
    }
    return card;
  }

  function renderItemGrid(section, comp) {
    const s = comp.settings || {};
    if (s.title) section.appendChild(el("div", "b-section-title", escapeHtml(s.title)));
    const grid = el("div", `b-grid cols-${s.columns || 3}`);
    section.appendChild(grid);
    loadItems(s.category_ids).then((items) => {
      grid.innerHTML = "";
      if (!items.length) { grid.appendChild(el("div", "b-card-meta", "No items to show yet.")); return; }
      items.forEach((item) => grid.appendChild(
        renderItemCard(item, s.show_stock, s.show_sku, s.show_low_stock_badge, s.tap_action)
      ));
    });
  }

  function renderToolGrid(section, comp) {
    const s = comp.settings || {};
    if (s.title) section.appendChild(el("div", "b-section-title", escapeHtml(s.title)));
    const grid = el("div", `b-grid cols-${s.columns || 3}`);
    section.appendChild(grid);
    loadTools(s.category_ids).then((tools) => {
      grid.innerHTML = "";
      if (!tools.length) { grid.appendChild(el("div", "b-card-meta", "No tools to show yet.")); return; }
      tools.forEach((tool) => {
        const card = el("div", "b-card");
        card.innerHTML = `
          <div class="b-card-name">${escapeHtml(tool.name)}</div>
          ${s.show_status !== false ? `<span class="b-badge" style="background:#374151;color:#e5e7eb;">${escapeHtml(tool.status_label)}</span>` : ""}
        `;
        grid.appendChild(card);
      });
    });
  }

  function renderStockSummary(section, comp) {
    const s = comp.settings || {};
    const row = el("div", "b-kpi-row");
    section.appendChild(row);
    jsonGet("/kiosk/api/summary").then((sum) => {
      row.innerHTML = "";
      if (s.show_total_items !== false) row.appendChild(kpi(sum.total_items, "Total items"));
      if (s.show_low_stock !== false) row.appendChild(kpi(sum.low_stock, "Low stock"));
      if (s.show_out_of_stock !== false) row.appendChild(kpi(sum.out_of_stock, "Out of stock"));
    }).catch(() => {});
  }

  function kpi(value, label) {
    const box = el("div", "b-kpi");
    box.innerHTML = `<div class="b-kpi-value">${value}</div><div class="b-kpi-label">${escapeHtml(label)}</div>`;
    return box;
  }

  function renderButtonRow(section, comp) {
    const s = comp.settings || {};
    const row = el("div", "b-button-row");
    (s.buttons || []).forEach((btn) => {
      const b = el("button", "b-action-btn", `${btn.icon ? `<i class="${btn.icon}"></i>` : ""} ${escapeHtml(btn.label || "Button")}`);
      if (btn.action === "logout") b.onclick = doLogout;
      else if (btn.action === "scan") b.onclick = () => { window.location.href = "/kiosk/scan"; };
      else if (btn.action === "url" && btn.url) b.onclick = () => { window.location.href = btn.url; };
      row.appendChild(b);
    });
    section.appendChild(row);
  }

  function renderTextBlock(section, comp) {
    const s = comp.settings || {};
    if (s.heading) section.appendChild(el("div", "b-text-heading", escapeHtml(s.heading)));
    if (s.body) section.appendChild(el("div", "b-text-body", escapeHtml(s.body).replace(/\n/g, "<br>")));
  }

  function renderSpacer(section, comp) {
    const s = comp.settings || {};
    const h = { sm: "12px", md: "28px", lg: "56px" }[s.height || "md"];
    section.style.height = h;
  }

  const RENDERERS = {
    header: renderHeader,
    scan_panel: renderScanPanel,
    category_grid: renderCategoryGrid,
    item_grid: renderItemGrid,
    tool_grid: renderToolGrid,
    stock_summary: renderStockSummary,
    button_row: renderButtonRow,
    text_block: renderTextBlock,
    spacer: renderSpacer,
  };

  function escapeHtml(str) {
    const d = document.createElement("div");
    d.textContent = str == null ? "" : String(str);
    return d.innerHTML;
  }

  async function renderAll() {
    const container = document.getElementById("browseComponents");
    container.innerHTML = "";
    const components = await loadLayout();
    await loadCategories();

    components.forEach((comp) => {
      if (comp.visible === false) return;
      const renderer = RENDERERS[comp.type];
      if (!renderer) return;
      const section = el("div", `b-section size-${comp.size || 'full'}`);
      renderer(section, comp);
      container.appendChild(section);
    });

    if (!components.length) {
      container.appendChild(el("div", "b-card-meta", "This kiosk has no dashboard layout published yet."));
    }
  }

  // ── Item quantity modal (shared for scan + card tap) ────────────────────

  function openItemModal(item) {
    if (opts.preview) return;
    selectedItem = item;
    qtyValue = "";
    document.getElementById("modalItemName").textContent = item.name;
    document.getElementById("modalItemStock").textContent = `In stock: ${item.display_stock || item.quantity}`;
    document.getElementById("modalQtyDisplay").textContent = "0";
    document.getElementById("itemModal").classList.add("open");
  }

  function closeItemModal() {
    document.getElementById("itemModal").classList.remove("open");
    selectedItem = null;
  }

  function bindModal() {
    document.getElementById("modalCancelBtn")?.addEventListener("click", closeItemModal);
    document.querySelectorAll("#modalKeypad .qty-key").forEach((btn) => {
      btn.addEventListener("click", () => {
        const key = btn.dataset.key;
        if (key === "clear") qtyValue = "";
        else if (key === "back") qtyValue = qtyValue.slice(0, -1);
        else qtyValue = (qtyValue + key).replace(/^0+(?=\d)/, "");
        document.getElementById("modalQtyDisplay").textContent = qtyValue || "0";
      });
    });
    document.getElementById("modalRemoveBtn")?.addEventListener("click", async () => {
      if (!selectedItem || !qtyValue) return;
      const qty = parseFloat(qtyValue);
      if (!qty) return;
      if (selectedItem.measurement_type === "count") {
        await jsonPost("/kiosk/api/quick-remove", { item_id: selectedItem.id, quantity: qty });
      } else {
        await jsonPost("/kiosk/api/quick-adjust-amount", { item_id: selectedItem.id, delta: -qty });
      }
      closeItemModal();
      allItems = null;
      renderAll();
    });
  }

  async function doLogout() {
    await jsonPost("/kiosk/api/logout", {});
    window.location.href = "/kiosk/";
  }

  function bindFooter() {
    document.getElementById("browseLogoutBtn")?.addEventListener("click", doLogout);
  }

  let idleTimer = null;
  function resetIdleTimer() {
    if (opts.preview) return;
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => { window.location.href = "/kiosk/"; }, (opts.idleTimeout || 60) * 1000);
  }

  function init(options) {
    opts = options || {};
    bindModal();
    bindFooter();
    renderAll();
    if (!opts.preview) {
      ["click", "keydown", "touchstart"].forEach((evt) =>
        document.addEventListener(evt, resetIdleTimer)
      );
      resetIdleTimer();
    }
  }

  return { init };
})();
