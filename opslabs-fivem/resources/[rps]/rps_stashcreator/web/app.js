/* ============================================================
   RPS STASH CREATOR — APP LOGIC
   ============================================================ */

'use strict';

/* ─────────────────── DATA ─────────────────── */

let JOBS_DATA = {};

// Main stash store
let stashes = [];

let editingStashId = null;
let captureContext = null; // { context: 'create'|'edit', rowIndex: number }
let deleteTargetId   = null;

/* ─────────────────── INIT ─────────────────── */
window.addEventListener('DOMContentLoaded', () => {
  renderStashList();
  updateActiveCount();
  updateEmptyHints('create');

  // The Enter key for coords is now handled by Lua since focus is disabled during capture
  window.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (captureContext) cancelApCapture();
      else {
        document.getElementById('appWrapper').style.display = 'none';
        postNUI('closeUI', {});
      }
    }
  });

  // NUI Message listener (for real FiveM integration)
  window.addEventListener('message', (event) => {
    const data = event.data;
    if (!data || !data.type) return;

    switch (data.type) {
      case 'openUI':
        document.getElementById('appWrapper').style.display = 'flex';
        if (data.jobs) JOBS_DATA = data.jobs;
        if (data.stashes) {
          // Empty tables from Lua can be sent as objects {}, make sure it's an array
          stashes = Array.isArray(data.stashes) ? data.stashes : Object.values(data.stashes);
          renderStashList();
          updateActiveCount();
        }
        break;
      case 'closeUI':
        document.getElementById('appWrapper').style.display = 'none';
        break;
      case 'coordsCaptured':
        if (captureContext && data.coords) {
          resolveCoordinates(data.coords.x, data.coords.y, data.coords.z);
        }
        break;
      case 'cancelCapture':
        if (captureContext) cancelApCapture();
        break;
    }
  });
});

/* ─────────────────── TABS ─────────────────── */
function switchTab(tab) {
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
  document.getElementById('tab-' + tab).classList.add('active');
  document.getElementById('pane-' + tab).classList.add('active');
}

/* ─────────────────── STASH LIST ─────────────────── */
function renderStashList(filter = '') {
  const list = document.getElementById('stashList');
  const empty = document.getElementById('emptyState');
  const filtered = stashes.filter(s => s.name.toLowerCase().includes(filter.toLowerCase()));
  list.innerHTML = '';

  if (filtered.length === 0) {
    empty.style.display = 'block';
    return;
  }
  empty.style.display = 'none';

  filtered.forEach((s, i) => {
    const jobCount  = s.jobs.length;
    const apCount   = s.accessPoints.length;
    const charCount = s.chars.length;

    const item = document.createElement('div');
    item.className = 'stash-item';
    item.style.animationDelay = `${i * 0.04}s`;
    item.innerHTML = `
      <div class="stash-item-icon">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <rect x="2" y="7" width="20" height="14" rx="2"/>
          <path d="M16 7V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2"/>
        </svg>
      </div>
      <div class="stash-item-info">
        <div class="stash-item-name">${escHtml(s.name)}</div>
        <div class="stash-item-meta">
          <span class="meta-chip">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/></svg>
            ${s.slots} slots
          </span>
          <span class="meta-chip">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87L18.18 21 12 17.77 5.82 21 7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>
            ${s.weight}kg
          </span>
          <span class="meta-chip">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
            ${jobCount} job${jobCount !== 1 ? 's' : ''}
          </span>
          <span class="meta-chip">
            <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><circle cx="12" cy="12" r="3"/><path d="M12 2v4M12 18v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83M1 12h4M19 12h4M4.22 19.78l2.83-2.83M16.95 7.05l2.83-2.83"/></svg>
            ${apCount} point${apCount !== 1 ? 's' : ''}
          </span>
        </div>
      </div>
      <div class="stash-item-actions">
        <button class="action-btn btn-edit" onclick="openEditPanel('${s.id}')">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>
          Edit
        </button>
        <button class="action-btn btn-delete" onclick="openDeleteModal('${s.id}')">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg>
          Delete
        </button>
      </div>
    `;
    list.appendChild(item);
  });
  updateActiveCount();
}

// Shows/hides the "no restrictions yet" placeholder for a ctx's job/char/AP
// lists, based on how many rows each currently has. Called after every
// add/remove/reset/populate so an empty section never just looks broken.
function updateEmptyHints(ctx) {
  const jobCount  = document.getElementById(`${ctx}-jobList`).querySelectorAll('.job-row').length;
  const charCount = document.getElementById(`${ctx}-charList`).querySelectorAll('.char-row').length;
  const apCount   = document.getElementById(`${ctx}-apList`).querySelectorAll('.ap-row').length;
  document.getElementById(`${ctx}-jobEmpty`).style.display  = jobCount  === 0 ? 'block' : 'none';
  document.getElementById(`${ctx}-charEmpty`).style.display = charCount === 0 ? 'block' : 'none';
  document.getElementById(`${ctx}-apEmpty`).style.display   = apCount   === 0 ? 'block' : 'none';
}

function filterStashes() {
  renderStashList(document.getElementById('searchBar').value);
}

function updateActiveCount() {
  document.getElementById('activeCount').textContent = stashes.length;
}

/* ─────────────────── EDIT PANEL ─────────────────── */
function openEditPanel(id) {
  const s = stashes.find(x => String(x.id) === String(id));
  if (!s) return;
  editingStashId = id;

  document.getElementById('editPanelTitle').textContent = 'Edit Stash';
  document.getElementById('editPanelSub').textContent   = `Modifying: ${s.name}`;
  document.getElementById('editIdBadge').textContent    = `#${String(id).slice(0, 8).toUpperCase()}`;

  document.getElementById('edit-name').value   = s.name;
  document.getElementById('edit-slots').value  = s.slots;
  document.getElementById('edit-weight').value = s.weight;

  // Jobs
  const jobList = document.getElementById('edit-jobList');
  jobList.innerHTML = `<div class="job-entry-header"><span>Job</span><span>Min Grade</span><span></span></div>`;
  s.jobs.forEach(j => addJobRow('edit', j.job, j.grade));

  // Chars
  const charList = document.getElementById('edit-charList');
  charList.innerHTML = '';
  s.chars.forEach(c => addCharRow('edit', c));

  // Access Points
  const apList = document.getElementById('edit-apList');
  apList.innerHTML = '';
  s.accessPoints.forEach(ap => addAccessPointWithCoords('edit', ap));

  updateEmptyHints('edit');

  // Open panel
  document.getElementById('editPanel').classList.add('open');
  document.getElementById('mainUI').classList.add('shifted');
}

function closeEditPanel() {
  document.getElementById('editPanel').classList.remove('open');
  document.getElementById('mainUI').classList.remove('shifted');
  editingStashId = null;
}

function saveEdit() {
  const name   = document.getElementById('edit-name').value.trim();
  const slots  = parseInt(document.getElementById('edit-slots').value);
  const weight = parseFloat(document.getElementById('edit-weight').value);

  if (!name)          { showToast('Stash name cannot be empty.', 'error'); return; }
  if (!slots || slots < 1)  { showToast('Slots must be at least 1.', 'error'); return; }
  if (!weight || weight < 1){ showToast('Weight must be at least 1kg.', 'error'); return; }

  const jobs  = collectJobRows('edit');
  const chars = collectCharRows('edit');
  const aps   = collectAccessPoints('edit');

  const idx = stashes.findIndex(x => String(x.id) === String(editingStashId));
  if (idx === -1) return;

  stashes[idx] = { ...stashes[idx], name, slots, weight, jobs, chars, accessPoints: aps };

  postNUI('saveStash', stashes[idx]);
  renderStashList(document.getElementById('searchBar').value);
  closeEditPanel();
  showToast(`"${name}" updated successfully.`, 'success');
}

/* ─────────────────── CREATE STASH ─────────────────── */
function createStash() {
  const name   = document.getElementById('create-name').value.trim();
  const slots  = parseInt(document.getElementById('create-slots').value);
  const weight = parseFloat(document.getElementById('create-weight').value);

  if (!name)          { showToast('Stash name cannot be empty.', 'error'); return; }
  if (!slots || slots < 1)  { showToast('Slots must be at least 1.', 'error'); return; }
  if (!weight || weight < 1){ showToast('Weight must be at least 1kg.', 'error'); return; }

  const jobs  = collectJobRows('create');
  const chars = collectCharRows('create');
  const aps   = collectAccessPoints('create');

  const uniqueId = Math.random().toString(36).substring(2, 10);
  const newStash = { id: uniqueId, name, slots, weight, jobs, chars, accessPoints: aps };
  stashes.push(newStash);

  postNUI('createStash', newStash);
  renderStashList();
  resetForm('create');
  switchTab('active');
  showToast(`"${name}" created successfully.`, 'success');
}

function resetForm(ctx) {
  document.getElementById(`${ctx}-name`).value   = '';
  document.getElementById(`${ctx}-slots`).value  = '';
  document.getElementById(`${ctx}-weight`).value = '';
  document.getElementById(`${ctx}-jobList`).innerHTML  = `<div class="job-entry-header"><span>Job</span><span>Min Grade</span><span></span></div>`;
  document.getElementById(`${ctx}-charList`).innerHTML = '';
  document.getElementById(`${ctx}-apList`).innerHTML   = '';
  updateEmptyHints(ctx);
}

/* ─────────────────── JOB ROWS ─────────────────── */
function addJobRow(ctx, selectedJob = '', selectedGrade = 0) {
  const container = document.getElementById(`${ctx}-jobList`);
  const row = document.createElement('div');
  row.className = 'job-row';

  // Job select
  const jobSelect = document.createElement('select');
  jobSelect.className = 'form-select';
  jobSelect.innerHTML = `<option value="">— Select Job —</option>`;
  Object.entries(JOBS_DATA).forEach(([key, data]) => {
    const opt = document.createElement('option');
    opt.value = key;
    opt.textContent = data.label;
    if (key === selectedJob) opt.selected = true;
    jobSelect.appendChild(opt);
  });

  // Grade select
  const gradeSelect = document.createElement('select');
  gradeSelect.className = 'form-select';

  function populateGrades(jobKey, selGrade) {
    gradeSelect.innerHTML = '';
    if (!jobKey || !JOBS_DATA[jobKey]) {
      gradeSelect.innerHTML = '<option value="">— Select Job First —</option>';
      return;
    }
    const gradesObj = JOBS_DATA[jobKey].grades;
    if (gradesObj) {
      Object.entries(gradesObj).forEach(([gradeNum, gradeInfo]) => {
        const opt = document.createElement('option');
        opt.value = gradeNum;
        opt.textContent = `${gradeNum} - ${gradeInfo.name || 'Grade'}`;
        if (gradeNum == selGrade) opt.selected = true;
        gradeSelect.appendChild(opt);
      });
    }
  }
  populateGrades(selectedJob, selectedGrade);

  jobSelect.addEventListener('change', () => populateGrades(jobSelect.value, 0));

  // Remove btn
  const rm = removeBtn(() => { row.remove(); updateEmptyHints(ctx); });

  row.appendChild(jobSelect);
  row.appendChild(gradeSelect);
  row.appendChild(rm);
  container.appendChild(row);
  updateEmptyHints(ctx);
}

function collectJobRows(ctx) {
  const rows = document.getElementById(`${ctx}-jobList`).querySelectorAll('.job-row');
  const result = [];
  rows.forEach(row => {
    const selects = row.querySelectorAll('select');
    const job   = selects[0]?.value;
    const grade = parseInt(selects[1]?.value || '0');
    if (job) result.push({ job, grade });
  });
  return result;
}

/* ─────────────────── CHAR ROWS ─────────────────── */
function addCharRow(ctx, charObj = null) {
  const container = document.getElementById(`${ctx}-charList`);
  const row = document.createElement('div');
  row.className = 'char-row';

  const inputWrap = document.createElement('div');
  inputWrap.className = 'char-search-wrap';
  inputWrap.style.position = 'relative';

  const input = document.createElement('input');
  input.className = 'form-input';
  input.placeholder = 'Type character name...';
  input.value = charObj ? charObj.label : '';

  const hiddenInput = document.createElement('input');
  hiddenInput.type = 'hidden';
  hiddenInput.className = 'char-hidden-id';
  hiddenInput.value = charObj ? charObj.id : '';

  const dropdown = document.createElement('div');
  dropdown.className = 'char-dropdown';
  dropdown.style.cssText = 'position:absolute;top:100%;left:0;width:100%;background:var(--surface-2);border:1px solid var(--glass-border);border-radius:var(--radius-sm);z-index:50;display:none;max-height:150px;overflow-y:auto;box-shadow:var(--shadow);';

  let debounceTimer;
  input.addEventListener('input', (e) => {
    clearTimeout(debounceTimer);
    const query = e.target.value.trim();
    if(query.length < 2) {
      dropdown.style.display = 'none';
      hiddenInput.value = ''; 
      return;
    }
    
    debounceTimer = setTimeout(() => {
      fetch(`https://rps_stashcreator/searchCharacters`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query })
      }).then(r => r.json()).then(results => {
        dropdown.innerHTML = '';
        if(!results || results.length === 0) {
          dropdown.style.display = 'none';
          return;
        }
        results.forEach(res => {
          const item = document.createElement('div');
          item.className = 'char-dropdown-item';
          item.style.cssText = 'padding:8px 12px;cursor:pointer;font-size:12px;border-bottom:1px solid var(--glass-border);color:var(--text);';
          item.textContent = `${res.name} (${res.citizenid})`;
          item.addEventListener('mouseenter', () => item.style.background = 'var(--glass)');
          item.addEventListener('mouseleave', () => item.style.background = 'transparent');
          item.addEventListener('click', () => {
            input.value = `${res.name} (${res.citizenid})`;
            hiddenInput.value = res.citizenid;
            dropdown.style.display = 'none';
          });
          dropdown.appendChild(item);
        });
        dropdown.style.display = 'block';
      }).catch(() => {});
    }, 300);
  });

  document.addEventListener('click', (e) => {
    if(!inputWrap.contains(e.target)) dropdown.style.display = 'none';
  });

  const rm = removeBtn(() => { row.remove(); updateEmptyHints(ctx); });
  inputWrap.appendChild(input);
  inputWrap.appendChild(hiddenInput);
  inputWrap.appendChild(dropdown);

  row.appendChild(inputWrap);
  row.appendChild(rm);
  container.appendChild(row);
  updateEmptyHints(ctx);
}

function collectCharRows(ctx) {
  const rows = document.getElementById(`${ctx}-charList`).querySelectorAll('.char-row');
  const result = [];
  rows.forEach(row => {
    const id = row.querySelector('.char-hidden-id')?.value;
    const label = row.querySelector('.form-input')?.value;
    if (id && label) result.push({ id, label });
  });
  return result;
}

/* ─────────────────── ACCESS POINTS ─────────────────── */
function addAccessPoint(ctx) {
  const container = document.getElementById(`${ctx}-apList`);
  const rowIndex  = container.querySelectorAll('.ap-row').length;

  const row = document.createElement('div');
  row.className = 'ap-row pending';
  row.dataset.ctx   = ctx;
  row.dataset.index = rowIndex;
  row.dataset.captured = 'false';

  row.innerHTML = `
    <div class="ap-waiting-badge">
      <div class="ap-waiting-dot"></div>
      Walk to location & press <kbd>Enter</kbd>
    </div>
  `;

  const rm = removeBtn(() => { row.remove(); updateEmptyHints(ctx); if (captureContext?.rowElement === row) cancelApCapture(); });
  row.appendChild(rm);
  container.appendChild(row);
  updateEmptyHints(ctx);

  // Begin capture
  captureContext = { ctx, rowElement: row };
  openApCaptureOverlay();
}

function addAccessPointWithCoords(ctx, ap) {
  const container = document.getElementById(`${ctx}-apList`);
  const row = document.createElement('div');
  row.className = 'ap-row';
  row.dataset.captured = 'true';
  row.dataset.x = ap.x;
  row.dataset.y = ap.y;
  row.dataset.z = ap.z;

  const radiusInput = document.createElement('input');
  radiusInput.type = 'number'; radiusInput.step = '0.1'; radiusInput.min = '0.5';
  radiusInput.className = 'form-input ap-radius-input';
  radiusInput.value = ap.radius || 1.5;
  radiusInput.title = 'Capture Radius (m)';

  row.innerHTML = `
    <span class="ap-label">AP</span>
    <div class="ap-coords">
      <span class="ap-coord-chip">X: ${ap.x.toFixed(2)}</span>
      <span class="ap-coord-chip">Y: ${ap.y.toFixed(2)}</span>
      <span class="ap-coord-chip">Z: ${ap.z.toFixed(2)}</span>
    </div>
    <span class="ap-label" style="font-size:10px;color:var(--text-dim)">r:</span>
  `;
  row.appendChild(radiusInput);
  row.appendChild(removeBtn(() => { row.remove(); updateEmptyHints(ctx); }));
  container.appendChild(row);
  updateEmptyHints(ctx);
}

function collectAccessPoints(ctx) {
  const rows = document.getElementById(`${ctx}-apList`).querySelectorAll('.ap-row[data-captured="true"]');
  const result = [];
  rows.forEach(row => {
    result.push({
      x: parseFloat(row.dataset.x),
      y: parseFloat(row.dataset.y),
      z: parseFloat(row.dataset.z),
      radius: parseFloat(row.querySelector('.ap-radius-input')?.value || 1.5),
    });
  });
  return result;
}

/* ─────────────────── AP CAPTURE OVERLAY ─────────────────── */
function openApCaptureOverlay() {
  // Hide the entire UI so the player can see the game world
  document.getElementById('appWrapper').style.display = 'none';
  postNUI('startCapture', {});
}

function resolveCoordinates(x, y, z) {
  if (!captureContext) return;
  const { ctx, rowElement } = captureContext;

  // Transform pending row into captured row
  rowElement.classList.remove('pending');
  rowElement.dataset.captured = 'true';
  rowElement.dataset.x = x;
  rowElement.dataset.y = y;
  rowElement.dataset.z = z;

  const radiusInput = document.createElement('input');
  radiusInput.type  = 'number'; radiusInput.step = '0.1'; radiusInput.min = '0.5';
  radiusInput.className = 'form-input ap-radius-input';
  radiusInput.value = '1.5';
  radiusInput.title = 'Capture Radius (m)';

  const rm = rowElement.querySelector('.remove-btn');
  rowElement.innerHTML = `
    <span class="ap-label">AP</span>
    <div class="ap-coords">
      <span class="ap-coord-chip">X: ${x.toFixed(2)}</span>
      <span class="ap-coord-chip">Y: ${y.toFixed(2)}</span>
      <span class="ap-coord-chip">Z: ${z.toFixed(2)}</span>
    </div>
    <span class="ap-label" style="font-size:10px;color:var(--text-dim)">r:</span>
  `;
  rowElement.appendChild(radiusInput);
  rowElement.appendChild(rm || removeBtn(() => rowElement.remove()));

  captureContext = null;
  document.getElementById('apCaptureOverlay').classList.remove('open');
  // Bring the UI back
  document.getElementById('appWrapper').style.display = 'flex';
  showToast(`Access point captured at (${x.toFixed(1)}, ${y.toFixed(1)}, ${z.toFixed(1)})`, 'success');
}

function cancelApCapture() {
  if (captureContext?.rowElement) captureContext.rowElement.remove();
  if (captureContext?.ctx) updateEmptyHints(captureContext.ctx);
  captureContext = null;
  document.getElementById('apCaptureOverlay').classList.remove('open');
  // Bring the UI back
  document.getElementById('appWrapper').style.display = 'flex';
}

/* ─────────────────── DELETE MODAL ─────────────────── */
function openDeleteModal(id) {
  const s = stashes.find(x => String(x.id) === String(id));
  if (!s) return;
  deleteTargetId = id;
  document.getElementById('deleteStashName').textContent = s.name;
  document.getElementById('deleteModal').classList.add('open');
}

function closeDeleteModal() {
  deleteTargetId = null;
  document.getElementById('deleteModal').classList.remove('open');
}

function confirmDelete() {
  if (!deleteTargetId) return;
  const s = stashes.find(x => String(x.id) === String(deleteTargetId));
  stashes = stashes.filter(x => String(x.id) !== String(deleteTargetId));
  postNUI('deleteStash', { id: deleteTargetId });
  renderStashList(document.getElementById('searchBar').value);
  closeDeleteModal();
  showToast(`"${s?.name || 'Stash'}" deleted.`, 'info');
}

/* ─────────────────── HELPERS ─────────────────── */
function removeBtn(onRemove) {
  const btn = document.createElement('button');
  btn.className = 'remove-btn';
  btn.title = 'Remove';
  btn.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`;
  btn.addEventListener('click', onRemove);
  return btn;
}

function showToast(message, type = 'info') {
  const container = document.getElementById('toastContainer');
  const t = document.createElement('div');
  t.className = `toast ${type}`;
  t.innerHTML = `<span class="toast-dot"></span>${escHtml(message)}`;
  container.appendChild(t);
  setTimeout(() => { t.classList.add('hide'); setTimeout(() => t.remove(), 300); }, 3200);
}

function escHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str));
  return div.innerHTML;
}

function postNUI(action, data = {}) {
  fetch(`https://rps_stashcreator/${action}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  }).catch(() => {}); // Silently fail outside FiveM
}

/* ─────────────────── CLOSE BTN ─────────────────── */
document.getElementById('closeBtn').addEventListener('click', () => {
  document.getElementById('appWrapper').style.display = 'none';
  postNUI('closeUI', {});
});
