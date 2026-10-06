let DOORS_DATA = {};
let JOBS_DATA = {};
let GANGS_DATA = {};

let currentEditId = null;
let activeTab = 'active';

// For entity picker
let capturedEntities = {
  create: [],
  edit: []
};

// ==========================================
// DOOR TYPE SELECT (click-to-open box, replaces the old Automatic Door toggle)
// ==========================================
const TYPE_ICON_ATTRS = 'width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
const DOOR_TYPES = [
  {
    value: 'normal', label: 'Normal Door',
    desc: 'A standard door — opens and closes manually, no special behavior.',
    icon: `<svg ${TYPE_ICON_ATTRS}><rect x="5" y="2" width="14" height="20" rx="1"/><circle cx="15.3" cy="12" r="0.6" fill="currentColor" stroke="none"/></svg>`
  },
  {
    value: 'automatic', label: 'Automatic Door',
    desc: 'Swings open on its own as a player gets close.',
    icon: `<svg ${TYPE_ICON_ATTRS}><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>`
  },
  {
    value: 'garage', label: 'Garage Door',
    desc: 'For garage, hangar, or warehouse-style vehicle entrances.',
    icon: `<svg ${TYPE_ICON_ATTRS}><rect x="3" y="4" width="18" height="16" rx="1"/><line x1="3" y1="9" x2="21" y2="9"/><line x1="3" y1="14" x2="21" y2="14"/></svg>`
  },
  {
    value: 'lab', label: 'Lab Door',
    desc: 'Sci-fi style access door for labs, bunkers, or secure facilities.',
    icon: `<svg ${TYPE_ICON_ATTRS}><path d="M9 2v6.5L4 17a2 2 0 0 0 1.8 3h12.4a2 2 0 0 0 1.8-3l-5-8.5V2"/><line x1="8" y1="2" x2="16" y2="2"/></svg>`
  },
  {
    value: 'sliding', label: 'Sliding Door',
    desc: 'For doors that slide open sideways instead of swinging.',
    icon: `<svg ${TYPE_ICON_ATTRS}><polyline points="18 8 22 12 18 16"/><polyline points="6 8 2 12 6 16"/><line x1="2" y1="12" x2="22" y2="12"/></svg>`
  },
];
const DOOR_TYPE_BY_VALUE = Object.fromEntries(DOOR_TYPES.map(t => [t.value, t]));

function renderDoorTypeDropdown(ctx) {
  const dropdown = document.getElementById(`${ctx}-doorTypeDropdown`);
  if (!dropdown || dropdown.dataset.built) return;
  dropdown.dataset.built = '1';
  DOOR_TYPES.forEach(type => {
    const item = document.createElement('div');
    item.className = 'type-option';
    item.dataset.value = type.value;
    item.innerHTML = `
      <span class="type-option-icon">${type.icon}</span>
      <span>
        <div class="type-option-name">${escHtml(type.label)}</div>
        <div class="type-option-desc">${escHtml(type.desc)}</div>
      </span>
    `;
    item.addEventListener('click', () => {
      setDoorType(ctx, type.value);
      formDirty[ctx] = true;
      refreshRequirements(ctx);
      closeDoorTypeDropdown(ctx);
    });
    dropdown.appendChild(item);
  });
}

function closeAllDoorTypeDropdowns() {
  document.querySelectorAll('.type-select.open').forEach(el => el.classList.remove('open'));
}

function closeDoorTypeDropdown(ctx) {
  const select = document.getElementById(`${ctx}-doorTypeSelect`);
  if (select) select.classList.remove('open');
}

function toggleDoorTypeDropdown(ctx) {
  const select = document.getElementById(`${ctx}-doorTypeSelect`);
  const wasOpen = select.classList.contains('open');
  closeAllDoorTypeDropdowns();
  if (!wasOpen) {
    renderDoorTypeDropdown(ctx);
    select.classList.add('open');
  }
}

document.addEventListener('click', (e) => {
  if (!e.target.closest('.type-select')) closeAllDoorTypeDropdowns();
});

function setDoorType(ctx, value) {
  const type = DOOR_TYPE_BY_VALUE[value] || DOOR_TYPES[0];
  const select = document.getElementById(`${ctx}-doorTypeSelect`);
  if (!select) return;
  select.dataset.value = type.value;
  document.getElementById(`${ctx}-doorTypeIcon`).innerHTML = type.icon;
  document.getElementById(`${ctx}-doorTypeLabel`).textContent = type.label;
  renderDoorTypeDropdown(ctx);
  document.getElementById(`${ctx}-doorTypeDropdown`).querySelectorAll('.type-option').forEach(opt => {
    opt.classList.toggle('selected', opt.dataset.value === type.value);
  });
}

function getDoorType(ctx) {
  const select = document.getElementById(`${ctx}-doorTypeSelect`);
  return (select && select.dataset.value) || 'normal';
}

// ==========================================
// UNSAVED CHANGES TRACKING
// ==========================================
let formDirty = { create: false, edit: false };
let pendingDiscardAction = null;

function setupDirtyTracking(ctx) {
  const form = document.getElementById(`${ctx}Form`);
  if (!form) return;
  const mark = () => { formDirty[ctx] = true; refreshRequirements(ctx); };
  form.addEventListener('input', mark);
  form.addEventListener('change', mark);
  form.addEventListener('click', (e) => {
    if (e.target.closest('.add-row-btn, .remove-btn, .capture-btn')) mark();
  });
}

function requestDiscardConfirm(action) {
  pendingDiscardAction = action;
  document.getElementById('unsavedModal').classList.add('open');
}
function closeUnsavedModal() {
  document.getElementById('unsavedModal').classList.remove('open');
  pendingDiscardAction = null;
}
function confirmDiscard() {
  const action = pendingDiscardAction;
  document.getElementById('unsavedModal').classList.remove('open');
  pendingDiscardAction = null;
  if (action) action();
}

function switchTabGuarded(tabId) {
  if (activeTab === 'create' && tabId !== 'create' && formDirty.create) {
    requestDiscardConfirm(() => { resetForm('create'); switchTab(tabId); });
    return;
  }
  switchTab(tabId);
}

function requestClosePanel() {
  if (document.getElementById('editPanel').classList.contains('open') && formDirty.edit) {
    requestDiscardConfirm(() => { closeEditPanel(true); doClosePanel(); });
    return;
  }
  if (activeTab === 'create' && formDirty.create) {
    requestDiscardConfirm(() => { resetForm('create'); doClosePanel(); });
    return;
  }
  doClosePanel();
}

function doClosePanel() {
  document.getElementById('appWrapper').classList.remove('show');
  postNUI('closeUI');
}

// ==========================================
// LIVE REQUIREMENTS CHECKLIST (Create tab)
// ==========================================
function refreshRequirements(ctx) {
  if (ctx !== 'create') return;

  const nameEl = document.getElementById(`${ctx}-name`);
  const name = nameEl ? nameEl.value.trim() : '';
  const isDouble = document.getElementById(`${ctx}-isDouble`).checked;
  const entities = capturedEntities[ctx] || [];
  const entityOk = isDouble ? entities.length === 2 : entities.length === 1;
  const nameOk = !!name;

  const checklist = document.getElementById(`${ctx}-reqChecklist`);
  if (checklist) {
    const nameItem = checklist.querySelector('[data-req="name"]');
    const entityItem = checklist.querySelector('[data-req="entity"]');
    if (nameItem) nameItem.classList.toggle('done', nameOk);
    if (entityItem) entityItem.classList.toggle('done', entityOk);
  }

  const submitBtn = document.getElementById(`${ctx}-submitBtn`);
  if (submitBtn) {
    submitBtn.disabled = !(nameOk && entityOk);
    submitBtn.title = submitBtn.disabled ? 'Complete the required steps above first' : '';
  }
}

function postNUI(event, data = {}) {
  return fetch(`https://${GetParentResourceName()}/${event}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  });
}

function escHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

let dirtyTrackingReady = false;

window.addEventListener('message', (e) => {
  const msg = e.data;
  if (msg.type === 'openUI') {
    JOBS_DATA = msg.jobs || {};
    GANGS_DATA = msg.gangs || {};
    DOORS_DATA = msg.doors || {};
    document.getElementById('appWrapper').classList.add('show');
    if (!dirtyTrackingReady) {
      dirtyTrackingReady = true;
      setupDirtyTracking('create');
      setupDirtyTracking('edit');
      setDoorType('create', 'normal');
      setDoorType('edit', 'normal');
    }
    switchTab('active');
    renderDoorList();
  } else if (msg.type === 'entityCaptured') {
    const ctx = currentEditId ? 'edit' : 'create';
    capturedEntities[ctx] = msg.data;
    renderEntityPreviews(ctx);
    formDirty[ctx] = true;
    refreshRequirements(ctx);
    document.getElementById('appWrapper').classList.add('show');
  } else if (msg.type === 'cancelEntityCapture') {
    document.getElementById('appWrapper').classList.add('show');
  }
});

document.getElementById('closeBtn').addEventListener('click', () => {
  requestClosePanel();
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (document.getElementById('unsavedModal').classList.contains('open')) {
      closeUnsavedModal();
      return;
    }
    const appWrapper = document.getElementById('appWrapper');
    if (appWrapper.classList.contains('show')) {
      requestClosePanel();
    }
  }
});

function switchTab(tabId) {
  activeTab = tabId;
  document.querySelectorAll('.tab-btn').forEach(btn => btn.classList.remove('active'));
  document.querySelectorAll('.tab-pane').forEach(pane => pane.classList.remove('active'));
  document.getElementById(`tab-${tabId}`).classList.add('active');
  document.getElementById(`pane-${tabId}`).classList.add('active');
  if (tabId === 'active') renderDoorList();
  if (tabId === 'create') refreshRequirements('create');
}

function updateActiveCount() {
  const count = Object.keys(DOORS_DATA).length;
  document.getElementById('activeCount').textContent = count;
  const list = document.getElementById('doorList');
  const empty = document.getElementById('emptyState');
  if (count === 0) {
    list.style.display = 'none';
    empty.style.display = 'flex';
  } else {
    list.style.display = 'flex';
    empty.style.display = 'none';
  }
}

function renderDoorList(filterText = '') {
  const container = document.getElementById('doorList');
  container.innerHTML = '';
  const query = filterText.toLowerCase();

  const entries = Object.values(DOORS_DATA);
  let matchCount = 0;

  entries.forEach(door => {
    if (door && door.name && door.name.toLowerCase().includes(query)) {
      matchCount++;
      const el = document.createElement('div');
      el.className = 'stash-item';
      
      const lockIcon = door.state === 1 
        ? `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#ef4444" stroke-width="2.5"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>`
        : `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#10b981" stroke-width="2.5"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 9.9-1"></path></svg>`;
        
      const entityType = door.isDouble ? "Double Door" : "Single Door";
      const doorTypeLabel = (DOOR_TYPE_BY_VALUE[door.doorType] || DOOR_TYPE_BY_VALUE.normal).label;

      el.innerHTML = `
        <div class="stash-item-info">
          <div class="stash-item-name">
            ${lockIcon}
            ${escHtml(door.name)}
          </div>
          <div class="stash-item-meta">ID: ${door.id} &bull; ${entityType} &bull; ${escHtml(doorTypeLabel)} &bull; Range: ${door.range}m</div>
        </div>
        <div class="stash-item-actions">
          <button class="action-btn btn-edit edit" title="Edit">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>
            Edit
          </button>
          <button class="action-btn btn-delete delete" title="Delete">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><line x1="10" y1="11" x2="10" y2="17"/><line x1="14" y1="11" x2="14" y2="17"/></svg>
            Delete
          </button>
        </div>
      `;
      
      el.querySelector('.edit').addEventListener('click', () => openEditPanel(door.id));
      el.querySelector('.delete').addEventListener('click', () => openDeleteModal(door.id, door.name));
      
      container.appendChild(el);
    }
  });

  const empty = document.getElementById('emptyState');
  if (matchCount === 0 && Object.keys(DOORS_DATA).length > 0) {
    container.style.display = 'none';
    empty.style.display = 'flex';
    empty.querySelector('.empty-title').textContent = 'No matches found';
    empty.querySelector('.empty-sub').textContent = 'Try adjusting your search query.';
  } else {
    updateActiveCount();
  }
}

function filterDoors() {
  const query = document.getElementById('searchBar').value;
  renderDoorList(query);
}

// ==========================================
// FORM BUILDERS
// ==========================================
function removeBtn(onClick) {
  const btn = document.createElement('button');
  btn.className = 'action-btn delete';
  btn.innerHTML = `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`;
  btn.onclick = onClick;
  return btn;
}

function addJobRow(ctx, selectedJob = '', selectedGrade = 0) {
  const container = document.getElementById(`${ctx}-jobList`);
  const row = document.createElement('div');
  row.className = 'job-row';
  
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

  row.appendChild(jobSelect);
  row.appendChild(gradeSelect);
  row.appendChild(removeBtn(() => row.remove()));
  container.appendChild(row);
}

function collectJobRows(ctx) {
  const rows = document.getElementById(`${ctx}-jobList`).querySelectorAll('.job-row');
  const result = [];
  rows.forEach(row => {
    const selects = row.querySelectorAll('select');
    const job = selects[0]?.value;
    const grade = parseInt(selects[1]?.value || '0');
    if (job) result.push({ job, grade });
  });
  return result;
}

function addGangRow(ctx, selectedGang = '', selectedGrade = 0) {
  const container = document.getElementById(`${ctx}-gangList`);
  const row = document.createElement('div');
  row.className = 'job-row'; 
  
  const gangSelect = document.createElement('select');
  gangSelect.className = 'form-select';
  gangSelect.innerHTML = `<option value="">— Select Gang —</option>`;
  Object.entries(GANGS_DATA).forEach(([key, data]) => {
    const opt = document.createElement('option');
    opt.value = key;
    opt.textContent = data.label;
    if (key === selectedGang) opt.selected = true;
    gangSelect.appendChild(opt);
  });

  const gradeSelect = document.createElement('select');
  gradeSelect.className = 'form-select';

  function populateGrades(gangKey, selGrade) {
    gradeSelect.innerHTML = '';
    if (!gangKey || !GANGS_DATA[gangKey]) {
      gradeSelect.innerHTML = '<option value="">— Select Gang First —</option>';
      return;
    }
    const gradesObj = GANGS_DATA[gangKey].grades;
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

  populateGrades(selectedGang, selectedGrade);
  gangSelect.addEventListener('change', () => populateGrades(gangSelect.value, 0));

  row.appendChild(gangSelect);
  row.appendChild(gradeSelect);
  row.appendChild(removeBtn(() => row.remove()));
  container.appendChild(row);
}

function collectGangRows(ctx) {
  const rows = document.getElementById(`${ctx}-gangList`).querySelectorAll('.job-row');
  const result = [];
  rows.forEach(row => {
    const selects = row.querySelectorAll('select');
    const gang = selects[0]?.value;
    const grade = parseInt(selects[1]?.value || '0');
    if (gang) result.push({ gang, grade });
  });
  return result;
}

function addCharRow(ctx, existingId = '', existingName = '') {
  const container = document.getElementById(`${ctx}-charList`);
  const row = document.createElement('div');
  row.className = 'char-row';

  const inputWrap = document.createElement('div');
  inputWrap.className = 'input-wrapper';
  inputWrap.style.flex = '1';

  const icon = document.createElement('div');
  icon.className = 'input-icon';
  icon.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>`;
  
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'form-input';
  input.placeholder = 'Search by character name...';
  if (existingName) input.value = existingName;

  const hiddenId = document.createElement('input');
  hiddenId.type = 'hidden';
  if (existingId) hiddenId.value = existingId;

  const dropdown = document.createElement('div');
  dropdown.className = 'search-dropdown';

  inputWrap.appendChild(icon);
  inputWrap.appendChild(input);
  inputWrap.appendChild(hiddenId);
  inputWrap.appendChild(dropdown);

  let searchTimeout;
  input.addEventListener('input', () => {
    clearTimeout(searchTimeout);
    const query = input.value.trim();
    
    hiddenId.value = '';
    
    if (query.length < 2) {
      dropdown.style.display = 'none';
      return;
    }
    
    searchTimeout = setTimeout(() => {
      postNUI('searchCharacters', { query }).then(resp => resp.json()).then(results => {
        dropdown.innerHTML = '';
        if (!results || results.length === 0) {
          dropdown.style.display = 'none';
          return;
        }
        
        results.forEach(char => {
          const item = document.createElement('div');
          item.className = 'search-item';
          item.innerHTML = `
            <span class="char-name">${escHtml(char.name)}</span>
            <span class="char-id">${escHtml(char.id)}</span>
          `;
          item.onclick = () => {
            input.value = char.name;
            hiddenId.value = char.id;
            dropdown.style.display = 'none';
          };
          dropdown.appendChild(item);
        });
        dropdown.style.display = 'block';
      });
    }, 300);
  });

  input.addEventListener('blur', () => {
    setTimeout(() => { dropdown.style.display = 'none'; }, 200);
  });

  row.appendChild(inputWrap);
  row.appendChild(removeBtn(() => row.remove()));
  container.appendChild(row);
}

function collectCharRows(ctx) {
  const rows = document.getElementById(`${ctx}-charList`).querySelectorAll('.char-row');
  const result = [];
  rows.forEach(row => {
    const hidden = row.querySelector('input[type="hidden"]');
    const input = row.querySelector('input[type="text"]');
    if (hidden && hidden.value) {
      result.push({ id: hidden.value, name: input.value });
    }
  });
  return result;
}

// ==========================================
// ENTITY CAPTURE
// ==========================================
function startEntityCapture(ctx) {
  const isDouble = document.getElementById(`${ctx}-isDouble`).checked;
  currentEditId = ctx === 'edit' ? currentEditId : null;
  postNUI('startEntityPicker', { isDouble });
  document.getElementById('appWrapper').classList.remove('show');
}

function renderEntityPreviews(ctx) {
  const container = document.getElementById(`${ctx}-entityPreviews`);
  container.innerHTML = '';
  const entities = capturedEntities[ctx];
  if (!entities || entities.length === 0) return;

  entities.forEach((ent, idx) => {
    const chip = document.createElement('div');
    chip.className = 'entity-preview-chip';
    chip.innerHTML = `
      <span>Door ${idx + 1}</span>
      <span class="entity-hash">${ent.model}</span>
      <span style="color:var(--text-muted)">(${ent.coords.x.toFixed(2)}, ${ent.coords.y.toFixed(2)}, ${ent.coords.z.toFixed(2)})</span>
    `;
    container.appendChild(chip);
  });
}

// ==========================================
// CREATE & EDIT LOGIC
// ==========================================
function resetForm(ctx) {
  document.getElementById(`${ctx}-name`).value   = '';
  document.getElementById(`${ctx}-isDouble`).checked = false;
  setDoorType(ctx, 'normal');
  document.getElementById(`${ctx}-range`).value = '2.0';
  document.getElementById(`${ctx}-keepOpen`).checked = false;
  document.getElementById(`${ctx}-hideIcon`).checked = false;
  document.getElementById(`${ctx}-lockpick`).checked = false;
  document.getElementById(`${ctx}-autolock`).value = '';
  
  document.getElementById(`${ctx}-jobList`).innerHTML  = `<div class="job-entry-header"><span>Job</span><span>Min Grade</span><span></span></div>`;
  document.getElementById(`${ctx}-gangList`).innerHTML = `<div class="job-entry-header"><span>Gang</span><span>Min Grade</span><span></span></div>`;
  document.getElementById(`${ctx}-charList`).innerHTML = '';
  document.getElementById(`${ctx}-entityPreviews`).innerHTML = '';
  capturedEntities[ctx] = [];
  formDirty[ctx] = false;
  refreshRequirements(ctx);
}

function createDoor() {
  const name = document.getElementById('create-name').value.trim();
  const isDouble = document.getElementById('create-isDouble').checked;
  const doorType = getDoorType('create');
  const range = parseFloat(document.getElementById('create-range').value);
  const keepOpen = document.getElementById('create-keepOpen').checked;
  const hideIcon = document.getElementById('create-hideIcon').checked;
  const lockpick = document.getElementById('create-lockpick').checked;
  const autolockVal = document.getElementById('create-autolock').value;
  const autolock = autolockVal ? parseInt(autolockVal) : 0;
  
  const jobs = collectJobRows('create');
  const gangs = collectGangRows('create');
  const chars = collectCharRows('create');
  
  if (!name) return showToast('Error', 'Please enter a door name.', 'error');
  if (isNaN(range) || range <= 0) return showToast('Error', 'Invalid range value.', 'error');
  
  const entities = capturedEntities['create'];
  if (isDouble && entities.length !== 2) return showToast('Error', 'Double doors require 2 entities to be selected.', 'error');
  if (!isDouble && entities.length !== 1) return showToast('Error', 'Please select 1 door entity.', 'error');

  const newDoor = {
    name,
    isDouble,
    doorType,
    range,
    keepOpen,
    hideIcon,
    lockpick,
    autolock,
    jobs,
    gangs,
    chars,
    doors: entities
  };

  postNUI('createDoor', newDoor);
  DOORS_DATA['temp'] = newDoor; // Temp update until server syncs
  renderDoorList();
  resetForm('create');
  switchTab('active');
  showToast('Success', `"${name}" created successfully.`, 'success');
}

function openEditPanel(id) {
  const door = DOORS_DATA[id];
  if (!door) return;
  currentEditId = id;

  document.getElementById('editPanelTitle').textContent = door.name;
  document.getElementById('editIdBadge').textContent = `#${id}`;

  document.getElementById('edit-name').value = door.name;
  document.getElementById('edit-isDouble').checked = door.isDouble;
  setDoorType('edit', door.doorType || (door.auto ? 'automatic' : 'normal'));
  document.getElementById('edit-range').value = door.range || 2.0;
  document.getElementById('edit-keepOpen').checked = door.keepOpen || false;
  document.getElementById('edit-hideIcon').checked = door.hideIcon || false;
  document.getElementById('edit-lockpick').checked = door.lockpick || false;
  document.getElementById('edit-autolock').value = door.autolock ? door.autolock : '';

  document.getElementById('edit-jobList').innerHTML = `<div class="job-entry-header"><span>Job</span><span>Min Grade</span><span></span></div>`;
  if (door.jobs) door.jobs.forEach(j => addJobRow('edit', j.job, j.grade));

  document.getElementById('edit-gangList').innerHTML = `<div class="job-entry-header"><span>Gang</span><span>Min Grade</span><span></span></div>`;
  if (door.gangs) door.gangs.forEach(g => addGangRow('edit', g.gang, g.grade));

  document.getElementById('edit-charList').innerHTML = '';
  if (door.chars) door.chars.forEach(c => addCharRow('edit', c.id, c.name));

  capturedEntities['edit'] = door.doors || [];
  renderEntityPreviews('edit');

  formDirty.edit = false;
  document.getElementById('editPanel').classList.add('open');
}

function closeEditPanel(force) {
  if (!force && formDirty.edit) {
    requestDiscardConfirm(() => closeEditPanel(true));
    return;
  }
  document.getElementById('editPanel').classList.remove('open');
  currentEditId = null;
  formDirty.edit = false;
}

function saveEdit() {
  if (!currentEditId) return;

  const name = document.getElementById('edit-name').value.trim();
  const isDouble = document.getElementById('edit-isDouble').checked;
  const doorType = getDoorType('edit');
  const range = parseFloat(document.getElementById('edit-range').value);
  const keepOpen = document.getElementById('edit-keepOpen').checked;
  const hideIcon = document.getElementById('edit-hideIcon').checked;
  const lockpick = document.getElementById('edit-lockpick').checked;
  const autolockVal = document.getElementById('edit-autolock').value;
  const autolock = autolockVal ? parseInt(autolockVal) : 0;

  const jobs = collectJobRows('edit');
  const gangs = collectGangRows('edit');
  const chars = collectCharRows('edit');

  if (!name) return showToast('Error', 'Please enter a door name.', 'error');
  if (isNaN(range) || range <= 0) return showToast('Error', 'Invalid range value.', 'error');

  const entities = capturedEntities['edit'];
  if (isDouble && entities.length !== 2) return showToast('Error', 'Double doors require 2 entities to be selected.', 'error');
  if (!isDouble && entities.length !== 1) return showToast('Error', 'Please select 1 door entity.', 'error');

  const updatedDoor = {
    id: currentEditId,
    name,
    isDouble,
    doorType,
    range,
    keepOpen,
    hideIcon,
    lockpick,
    autolock,
    jobs,
    gangs,
    chars,
    doors: entities
  };

  postNUI('saveDoor', updatedDoor);
  DOORS_DATA[currentEditId] = updatedDoor;
  renderDoorList(document.getElementById('searchBar').value);
  closeEditPanel(true);
  showToast('Success', `"${name}" updated successfully.`, 'success');
}

// ==========================================
// DELETE MODAL
// ==========================================
let deleteId = null;
function openDeleteModal(id, name) {
  deleteId = id;
  document.getElementById('deleteDoorName').textContent = name;
  document.getElementById('deleteModal').classList.add('open');
}
function closeDeleteModal() {
  document.getElementById('deleteModal').classList.remove('open');
  deleteId = null;
}
function confirmDelete() {
  if (!deleteId) return;
  postNUI('deleteDoor', { id: deleteId });
  delete DOORS_DATA[deleteId];
  renderDoorList(document.getElementById('searchBar').value);
  closeDeleteModal();
  showToast('Deleted', 'Door has been permanently deleted.', 'success');
}

// ==========================================
// TOAST NOTIFICATIONS
// ==========================================
function showToast(title, msg, type = 'info') {
  const container = document.getElementById('toastContainer');
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.innerHTML = `
    <div class="toast-dot"></div>
    <div style="flex:1">
      <div style="font-size:13px; font-weight:600; color:#fff; margin-bottom:2px;">${title}</div>
      <div style="font-size:12px; color:var(--text-muted); line-height:1.4;">${msg}</div>
    </div>
  `;
  container.appendChild(toast);
  setTimeout(() => { toast.classList.add('hide'); }, 4000);
  setTimeout(() => { toast.remove(); }, 4300);
}
