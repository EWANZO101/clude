const BuilderUI = (function () {
  let catalog = { component_types: [], sizes: ["sm", "md", "lg", "full"] };
  let categories = [];
  let layouts = [];
  let currentLayout = null;   // full layout object from the API
  let components = [];        // working copy of the draft being edited
  let history = [];
  let historyIndex = -1;
  let selectedId = null;
  let dirty = false;

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]').content;
  }

  async function req(method, url, body) {
    const opts = { method, headers: { "Content-Type": "application/json", "X-CSRFToken": csrfToken() } };
    if (body !== undefined) opts.body = JSON.stringify(body);
    const r = await fetch(url, opts);
    let data = null;
    try { data = await r.json(); } catch (e) { /* no body */ }
    if (!r.ok) {
      const err = new Error((data && (data.error || data.message)) || `Request failed (${r.status})`);
      err.details = data && data.details;
      throw err;
    }
    return data;
  }

  function showMessage(text, isError) {
    const box = document.getElementById("builderMessage");
    box.textContent = text;
    box.className = "builder-message " + (isError ? "err" : "ok");
    box.style.display = "block";
    if (!isError) setTimeout(() => { box.style.display = "none"; }, 3500);
  }

  function showErrorList(title, errors) {
    const box = document.getElementById("builderMessage");
    box.textContent = title + (errors && errors.length ? ":\n• " + errors.join("\n• ") : "");
    box.className = "builder-message err";
    box.style.display = "block";
  }

  // ── History (undo/redo) ────────────────────────────────────────────────

  function pushHistory() {
    history = history.slice(0, historyIndex + 1);
    history.push(JSON.stringify(components));
    historyIndex = history.length - 1;
    dirty = true;
    updateUndoRedoButtons();
  }

  function undo() {
    if (historyIndex <= 0) return;
    historyIndex--;
    components = JSON.parse(history[historyIndex]);
    selectedId = null;
    renderCanvas();
    renderPropertyPanel();
    updateUndoRedoButtons();
  }

  function redo() {
    if (historyIndex >= history.length - 1) return;
    historyIndex++;
    components = JSON.parse(history[historyIndex]);
    selectedId = null;
    renderCanvas();
    renderPropertyPanel();
    updateUndoRedoButtons();
  }

  function updateUndoRedoButtons() {
    document.getElementById("undoBtn").disabled = historyIndex <= 0;
    document.getElementById("redoBtn").disabled = historyIndex >= history.length - 1;
  }

  // ── Loading ──────────────────────────────────────────────────────────────

  async function loadCatalogAndCategories() {
    const [c, cats] = await Promise.all([
      req("GET", "/builder/api/catalog"),
      req("GET", "/builder/api/categories"),
    ]);
    catalog = c;
    categories = cats;
  }

  async function loadLayouts() {
    layouts = await req("GET", "/builder/api/layouts");
    const select = document.getElementById("layoutSelect");
    select.innerHTML = layouts.map((l) => `<option value="${l.id}">${escapeHtml(l.name)}${l.target_device ? ` (${escapeHtml(l.target_device)})` : ""}${l.is_default ? " ★" : ""}</option>`).join("");
    select.onchange = () => switchLayout(parseInt(select.value));
  }

  async function switchLayout(id) {
    if (!id) return;
    currentLayout = await req("GET", `/builder/api/layouts/${id}`);
    components = currentLayout.draft_components || [];
    history = [JSON.stringify(components)];
    historyIndex = 0;
    selectedId = null;
    dirty = false;
    document.getElementById("layoutSelect").value = id;
    updateStatusBadge();
    renderCanvas();
    renderPropertyPanel();
    updateUndoRedoButtons();
  }

  function updateStatusBadge() {
    const badge = document.getElementById("layoutStatusBadge");
    const status = currentLayout ? currentLayout.status : "draft";
    badge.textContent = status === "modified" ? "Unpublished changes" : status;
    badge.className = "b-status-badge status-" + status;
  }

  // ── Palette ──────────────────────────────────────────────────────────────

  function renderPalette() {
    const el = document.getElementById("palette");
    el.innerHTML = "";
    catalog.component_types.forEach((ct) => {
      const item = document.createElement("div");
      item.className = "palette-item";
      item.dataset.type = ct.type;
      item.innerHTML = `<i class="${ct.icon}"></i><div><div>${escapeHtml(ct.label)}</div><small>${escapeHtml(ct.description || "")}</small></div>`;
      item.addEventListener("dblclick", () => addComponent(ct.type));
      el.appendChild(item);
    });

    new Sortable(el, {
      group: { name: "builder-shared", pull: "clone", put: false },
      sort: false,
      animation: 150,
    });
  }

  function defaultsFor(type) {
    const defn = catalog.component_types.find((c) => c.type === type);
    const settings = {};
    (defn ? defn.settings : []).forEach((f) => { settings[f.key] = f.default; });
    return settings;
  }

  function labelFor(type) {
    const defn = catalog.component_types.find((c) => c.type === type);
    return defn ? defn.label : type;
  }

  function iconFor(type) {
    const defn = catalog.component_types.find((c) => c.type === type);
    return defn ? defn.icon : "fa-solid fa-square";
  }

  function addComponent(type, atIndex) {
    const comp = {
      id: `${type}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
      type, size: "full", visible: true, settings: defaultsFor(type),
    };
    if (atIndex === undefined || atIndex < 0) components.push(comp);
    else components.splice(atIndex, 0, comp);
    pushHistory();
    renderCanvas();
    selectComponent(comp.id);
  }

  // ── Canvas ───────────────────────────────────────────────────────────────

  function renderCanvas() {
    const el = document.getElementById("canvas");
    el.innerHTML = "";
    if (!components.length) {
      el.innerHTML = '<div class="canvas-empty">Drag a section here from the left, or double-click one to add it.</div>';
    }
    components.forEach((comp) => {
      const card = document.createElement("div");
      card.className = "canvas-card" + (comp.id === selectedId ? " selected" : "") + (comp.visible === false ? " cc-hidden" : "");
      card.dataset.id = comp.id;
      card.innerHTML = `
        <i class="fas fa-grip-vertical drag-handle"></i>
        <i class="${iconFor(comp.type)} cc-icon"></i>
        <div class="cc-body">
          <div class="cc-title">${escapeHtml(labelFor(comp.type))}</div>
          <div class="cc-sub">${escapeHtml(comp.type)}</div>
        </div>
        <span class="cc-size">${comp.size}</span>
        <div class="cc-actions">
          <button data-action="toggle" title="Show/hide"><i class="fas fa-eye${comp.visible === false ? "-slash" : ""}"></i></button>
          <button data-action="delete" title="Remove"><i class="fas fa-trash"></i></button>
        </div>
      `;
      card.addEventListener("click", (e) => {
        if (e.target.closest("[data-action]")) return;
        selectComponent(comp.id);
      });
      card.querySelector('[data-action="toggle"]').addEventListener("click", () => {
        comp.visible = comp.visible === false ? true : false;
        pushHistory();
        renderCanvas();
      });
      card.querySelector('[data-action="delete"]').addEventListener("click", () => {
        components = components.filter((c) => c.id !== comp.id);
        if (selectedId === comp.id) selectedId = null;
        pushHistory();
        renderCanvas();
        renderPropertyPanel();
      });
      el.appendChild(card);
    });

    new Sortable(el, {
      group: { name: "builder-shared", pull: false, put: true },
      handle: ".drag-handle",
      animation: 150,
      onAdd: function (evt) {
        // A palette item was dropped in — evt.item is the cloned palette
        // node; read its type, remove the raw clone, and insert a real
        // component in its place at the drop index.
        const type = evt.item.dataset.type;
        evt.item.remove();
        if (type) addComponent(type, evt.newIndex);
      },
      onUpdate: function () {
        const order = Array.from(el.children).map((c) => c.dataset.id).filter(Boolean);
        components.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
        pushHistory();
      },
    });
  }

  function selectComponent(id) {
    selectedId = id;
    renderCanvas();
    renderPropertyPanel();
  }

  // ── Property panel ─────────────────────────────────────────────────────

  function renderPropertyPanel() {
    const panel = document.getElementById("propertyPanel");
    const comp = components.find((c) => c.id === selectedId);
    if (!comp) {
      panel.innerHTML = '<div class="property-empty">Select a section on the left to edit it.</div>';
      return;
    }
    const defn = catalog.component_types.find((c) => c.type === comp.type);
    let html = `<div class="property-field"><label>Width</label><div class="property-size-row" id="sizeRow">
      ${catalog.sizes.map((s) => `<button data-size="${s}" class="${comp.size === s ? "active" : ""}">${s}</button>`).join("")}
    </div></div>`;

    (defn ? defn.settings : []).forEach((field) => {
      html += renderField(comp, field);
    });

    html += '<button class="btn btn-secondary property-delete-btn" id="deleteSelectedBtn"><i class="fas fa-trash"></i> Remove this section</button>';
    panel.innerHTML = html;

    panel.querySelectorAll("#sizeRow button").forEach((btn) => {
      btn.addEventListener("click", () => {
        comp.size = btn.dataset.size;
        pushHistory();
        renderCanvas();
        renderPropertyPanel();
      });
    });

    bindFieldEvents(panel, comp, defn);

    document.getElementById("deleteSelectedBtn").addEventListener("click", () => {
      components = components.filter((c) => c.id !== comp.id);
      selectedId = null;
      pushHistory();
      renderCanvas();
      renderPropertyPanel();
    });
  }

  function renderField(comp, field) {
    const value = comp.settings[field.key];
    if (field.type === "text") {
      return `<div class="property-field"><label>${escapeHtml(field.label)}</label>
        <input type="text" class="form-input" data-key="${field.key}" value="${escapeAttr(value || "")}" /></div>`;
    }
    if (field.type === "textarea") {
      return `<div class="property-field"><label>${escapeHtml(field.label)}</label>
        <textarea data-key="${field.key}">${escapeHtml(value || "")}</textarea></div>`;
    }
    if (field.type === "bool") {
      return `<div class="property-field property-bool">
        <input type="checkbox" data-key="${field.key}" id="f-${field.key}" ${value ? "checked" : ""} />
        <label for="f-${field.key}" style="margin:0;">${escapeHtml(field.label)}</label></div>`;
    }
    if (field.type === "select") {
      return `<div class="property-field"><label>${escapeHtml(field.label)}</label>
        <select data-key="${field.key}">
          ${(field.options || []).map((o) => `<option value="${o}" ${value === o ? "selected" : ""}>${o}</option>`).join("")}
        </select></div>`;
    }
    if (field.type === "category_multi") {
      const selected = new Set(value || []);
      return `<div class="property-field"><label>${escapeHtml(field.label)}</label>
        <div class="category-check-list" data-key="${field.key}">
          ${categories.length ? categories.map((c) => `
            <label><input type="checkbox" value="${c.id}" ${selected.has(c.id) ? "checked" : ""} /> ${escapeHtml(c.name)}</label>
          `).join("") : '<span style="color:#6b7280;font-size:12px;">No categories yet.</span>'}
        </div></div>`;
    }
    if (field.type === "button_list") {
      const list = value || [];
      return `<div class="property-field"><label>${escapeHtml(field.label)}</label>
        <div data-key="${field.key}" class="button-list-container">
          ${list.map((b, i) => `
            <div class="button-list-row" data-index="${i}">
              <input type="text" class="btn-label-input" placeholder="Label" value="${escapeAttr(b.label || "")}" />
              <select class="btn-action-select">
                <option value="scan" ${b.action === "scan" ? "selected" : ""}>Go to Scan</option>
                <option value="logout" ${b.action === "logout" ? "selected" : ""}>Log out</option>
                <option value="url" ${b.action === "url" ? "selected" : ""}>Open URL</option>
              </select>
              <button type="button" class="btn btn-secondary btn-sm remove-btn-row"><i class="fas fa-xmark"></i></button>
            </div>`).join("")}
        </div>
        <button type="button" class="btn btn-secondary btn-sm" id="addButtonRowBtn" style="margin-top:6px;"><i class="fas fa-plus"></i> Add button</button>
      </div>`;
    }
    return "";
  }

  function bindFieldEvents(panel, comp, defn) {
    panel.querySelectorAll("[data-key]").forEach((input) => {
      if (input.classList.contains("category-check-list") || input.classList.contains("button-list-container")) return;
      const key = input.dataset.key;
      const evt = (input.tagName === "SELECT" || input.type === "checkbox") ? "change" : "blur";
      input.addEventListener(evt, () => {
        comp.settings[key] = input.type === "checkbox" ? input.checked : input.value;
        pushHistory();
        renderCanvas();
      });
    });

    panel.querySelectorAll(".category-check-list").forEach((wrap) => {
      const key = wrap.dataset.key;
      wrap.querySelectorAll("input[type=checkbox]").forEach((cb) => {
        cb.addEventListener("change", () => {
          const ids = Array.from(wrap.querySelectorAll("input[type=checkbox]:checked")).map((c) => parseInt(c.value));
          comp.settings[key] = ids;
          pushHistory();
        });
      });
    });

    const buttonListWrap = panel.querySelector(".button-list-container");
    if (buttonListWrap) {
      const key = buttonListWrap.dataset.key;
      const syncFromDom = () => {
        const rows = Array.from(buttonListWrap.querySelectorAll(".button-list-row"));
        comp.settings[key] = rows.map((row) => ({
          label: row.querySelector(".btn-label-input").value,
          action: row.querySelector(".btn-action-select").value,
        }));
        pushHistory();
      };
      buttonListWrap.querySelectorAll(".btn-label-input, .btn-action-select").forEach((input) => {
        input.addEventListener(input.tagName === "SELECT" ? "change" : "blur", syncFromDom);
      });
      buttonListWrap.querySelectorAll(".remove-btn-row").forEach((btn) => {
        btn.addEventListener("click", () => {
          btn.closest(".button-list-row").remove();
          syncFromDom();
          renderPropertyPanel();
        });
      });
      const addBtn = panel.querySelector("#addButtonRowBtn");
      if (addBtn) addBtn.addEventListener("click", () => {
        comp.settings[key] = (comp.settings[key] || []).concat([{ label: "New Button", action: "scan" }]);
        pushHistory();
        renderPropertyPanel();
      });
    }
  }

  // ── Layout actions ──────────────────────────────────────────────────────

  async function saveDraft() {
    try {
      currentLayout = await req("PUT", `/builder/api/layouts/${currentLayout.id}`, { components });
      dirty = false;
      updateStatusBadge();
      showMessage("Draft saved.");
    } catch (e) {
      showErrorList(e.message, e.details);
    }
  }

  async function publish() {
    await saveDraft();
    try {
      currentLayout = await req("POST", `/builder/api/layouts/${currentLayout.id}/publish`);
      updateStatusBadge();
      showMessage("Published — kiosks using this layout will pick it up now.");
    } catch (e) {
      showErrorList("Can't publish yet", e.details || [e.message]);
    }
  }

  async function newLayout() {
    const name = prompt("Name for the new layout:");
    if (!name) return;
    const targetDevice = prompt("Limit to one kiosk device name? (leave blank for all kiosks)") || "";
    const layout = await req("POST", "/builder/api/layouts", { name, target_device: targetDevice });
    await loadLayouts();
    await switchLayout(layout.id);
  }

  async function duplicateLayout() {
    if (!currentLayout) return;
    const name = prompt("Name for the copy:", `Copy of ${currentLayout.name}`);
    if (!name) return;
    const layout = await req("POST", `/builder/api/layouts/${currentLayout.id}/duplicate`, { name });
    await loadLayouts();
    await switchLayout(layout.id);
  }

  async function resetLayout() {
    if (!currentLayout) return;
    if (!confirm("Reset this layout's draft back to the default template? Unsaved changes will be lost.")) return;
    currentLayout = await req("POST", `/builder/api/layouts/${currentLayout.id}/reset`);
    components = currentLayout.draft_components || [];
    history = [JSON.stringify(components)];
    historyIndex = 0;
    updateUndoRedoButtons();
    updateStatusBadge();
    renderCanvas();
    renderPropertyPanel();
    showMessage("Draft reset to default. Publish when you're ready.");
  }

  async function deleteLayout() {
    if (!currentLayout) return;
    if (!confirm(`Delete layout "${currentLayout.name}"? This can't be undone.`)) return;
    await req("DELETE", `/builder/api/layouts/${currentLayout.id}`);
    await loadLayouts();
    if (layouts.length) await switchLayout(layouts[0].id);
    else { currentLayout = null; components = []; renderCanvas(); renderPropertyPanel(); }
    showMessage("Layout deleted.");
  }

  // ── Preview ──────────────────────────────────────────────────────────────

  async function openPreview() {
    await saveDraft();
    await refreshPreview();
    openModal("previewModal");
  }

  async function refreshPreview() {
    if (!currentLayout) return;
    const { preview_path } = await req("POST", `/builder/api/layouts/${currentLayout.id}/preview-token`);
    document.getElementById("previewFrame").src = window.API_PUBLIC_URL + preview_path;
  }

  function openHelp() { openModal("helpModal"); }

  // ── Utils ────────────────────────────────────────────────────────────────

  function escapeHtml(str) {
    const d = document.createElement("div");
    d.textContent = str == null ? "" : String(str);
    return d.innerHTML;
  }
  function escapeAttr(str) { return escapeHtml(str).replace(/"/g, "&quot;"); }

  // ── Init ─────────────────────────────────────────────────────────────────

  async function init() {
    document.getElementById("undoBtn").addEventListener("click", undo);
    document.getElementById("redoBtn").addEventListener("click", redo);

    await loadCatalogAndCategories();
    renderPalette();
    await loadLayouts();

    if (layouts.length) {
      await switchLayout(layouts[0].id);
    } else {
      // No layouts at all yet — offer to create the first one straight away.
      const layout = await req("POST", "/builder/api/layouts", { name: "Default Kiosk" });
      await loadLayouts();
      await switchLayout(layout.id);
    }
  }

  return {
    init, newLayout, duplicateLayout, resetLayout, deleteLayout,
    saveDraft, publish, openPreview, refreshPreview, openHelp,
  };
})();
