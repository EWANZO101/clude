/* Ticket attachments: chunked uploads (images + videos from 1 second to 5 minutes) and
   rendering of attachments inside conversation messages.
   Used by tickets/new.html and tickets/view.html. */
(function () {
  const IMAGE_EXT = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif'];
  const VIDEO_EXT = ['mp4', 'm4v', 'mov', 'webm', 'mkv', 'avi'];
  const MAX_BYTES = 2 * 1024 * 1024 * 1024;
  const VIDEO_MIN = 1, VIDEO_MAX = 300;

  function extOf(name) { const i = name.lastIndexOf('.'); return i < 0 ? '' : name.slice(i + 1).toLowerCase(); }
  function fmtSize(n) {
    if (n >= 1073741824) return (n / 1073741824).toFixed(2) + ' GB';
    if (n >= 1048576) return (n / 1048576).toFixed(1) + ' MB';
    return Math.max(1, Math.round(n / 1024)) + ' KB';
  }
  function fmtDur(s) { s = Math.round(s); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); }
  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  // Ask the browser for a video's length; null if it can't decode the format.
  function videoDuration(file) {
    return new Promise(resolve => {
      const v = document.createElement('video');
      const url = URL.createObjectURL(file);
      const done = d => { URL.revokeObjectURL(url); resolve(d); };
      v.preload = 'metadata';
      v.onloadedmetadata = () => done(isFinite(v.duration) ? v.duration : null);
      v.onerror = () => done(null);
      setTimeout(() => done(null), 8000);
      v.src = url;
    });
  }

  function Uploader(opts) {
    this.ticketId = opts.ticketId || null;
    this.input = opts.input;
    this.tray = opts.tray;
    this.onChange = opts.onChange || function () {};
    this.items = [];
    this.input.addEventListener('change', () => {
      this.add(Array.from(this.input.files));
      this.input.value = '';
    });
  }

  Uploader.prototype.add = async function (files) {
    for (const file of files) {
      const item = { file, state: 'checking', progress: 0, id: null, error: null, ctrl: null };
      this.items.push(item);
      this._render(item);
      const ext = extOf(file.name);
      const kind = IMAGE_EXT.includes(ext) ? 'image' : (VIDEO_EXT.includes(ext) ? 'video' : null);
      if (!kind) this._fail(item, 'Only images and videos can be attached.');
      else if (file.size > MAX_BYTES) this._fail(item, 'Too large — max 2 GB.');
      else if (file.size === 0) this._fail(item, 'File is empty.');
      else {
        if (kind === 'video') {
          const d = await videoDuration(file);
          if (d != null && (d < VIDEO_MIN || d > VIDEO_MAX)) {
            this._fail(item, `Videos must be 1 second to 5 minutes (this is ${fmtDur(d)}).`);
            continue;
          }
          if (d != null) item.meta.textContent += ' · ' + fmtDur(d);
        }
        item.state = 'queued';
        this._update(item);
        if (this.ticketId) this._upload(item);
      }
    }
  };

  Uploader.prototype._render = function (item) {
    const row = el('div', 'up-item flex items-center gap-3 p-2 rounded-lg border border-ink-600 bg-ink-900/50');
    const thumb = el('div', 'w-10 h-10 rounded-md bg-ink-800 overflow-hidden shrink-0 flex items-center justify-center text-[10px] text-gray-400');
    if (item.file.type.startsWith('image/') && item.file.size < 30 * 1048576) {
      const img = el('img', 'w-full h-full object-cover'); img.alt = '';
      img.src = URL.createObjectURL(item.file); thumb.appendChild(img);
    } else {
      thumb.textContent = extOf(item.file.name).toUpperCase() || 'FILE';
    }
    const mid = el('div', 'flex-1 min-w-0');
    const name = el('div', 'text-xs text-gray-200 truncate', item.file.name);
    item.meta = el('div', 'text-[10px] text-gray-500', fmtSize(item.file.size));
    const bar = el('div', 'h-1 mt-1 rounded bg-ink-700 overflow-hidden');
    item.fill = el('div', 'h-full bg-ops-500 transition-all'); item.fill.style.width = '0%';
    bar.appendChild(item.fill);
    item.status = el('div', 'text-[10px] mt-0.5');
    mid.append(name, item.meta, bar, item.status);
    const rm = el('button', 'text-gray-500 hover:text-red-300 text-lg leading-none px-1', '×');
    rm.type = 'button'; rm.title = 'Remove'; rm.setAttribute('aria-label', 'Remove ' + item.file.name);
    rm.addEventListener('click', () => this.remove(item));
    row.append(thumb, mid, rm);
    item.row = row;
    this.tray.appendChild(row);
    this.tray.classList.remove('hidden');
    this._update(item);
  };

  Uploader.prototype._update = function (item) {
    const labels = { checking: 'Checking…', queued: this.ticketId ? 'Waiting…' : 'Ready to upload',
                     uploading: `Uploading ${Math.floor(item.progress * 100)}%`, verifying: 'Verifying…',
                     ready: '✓ Attached', error: item.error };
    item.status.textContent = labels[item.state] || '';
    item.status.className = 'text-[10px] mt-0.5 ' + (item.state === 'error' ? 'text-red-300' : item.state === 'ready' ? 'text-green-300' : 'text-gray-400');
    item.fill.style.width = (item.state === 'ready' ? 100 : Math.floor(item.progress * 100)) + '%';
    if (item.state === 'error') item.fill.className = 'h-full bg-red-500';
    this.onChange();
  };

  Uploader.prototype._fail = function (item, msg) { item.state = 'error'; item.error = msg; this._update(item); };

  Uploader.prototype.remove = async function (item) {
    if (item.ctrl) item.ctrl.abort();
    this.items = this.items.filter(i => i !== item);
    item.row.remove();
    if (!this.items.length) this.tray.classList.add('hidden');
    this.onChange();
    if (item.id && this.ticketId) {
      try { await fetch(`/tickets/${this.ticketId}/uploads/${item.id}`, { method: 'DELETE' }); } catch (e) {}
    }
  };

  async function jsonOrError(r) {
    try { return await r.json(); } catch (e) { return { ok: false, error: `Server error (${r.status})` }; }
  }

  Uploader.prototype._upload = async function (item) {
    const tid = this.ticketId;
    item.state = 'uploading'; item.ctrl = new AbortController(); this._update(item);
    try {
      let r = await fetch(`/tickets/${tid}/uploads`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'Accept': 'application/json' },
        body: JSON.stringify({ name: item.file.name, size: item.file.size }), signal: item.ctrl.signal,
      });
      let d = await jsonOrError(r);
      if (!d.ok) throw new Error(d.error);
      item.id = d.id;
      const chunk = d.chunk_size;
      let offset = 0, retries = 0;
      while (offset < item.file.size) {
        const blob = item.file.slice(offset, Math.min(offset + chunk, item.file.size));
        try {
          r = await fetch(`/tickets/${tid}/uploads/${item.id}?offset=${offset}`, {
            method: 'PUT', body: blob, headers: { 'Content-Type': 'application/octet-stream' }, signal: item.ctrl.signal,
          });
          d = await jsonOrError(r);
        } catch (e) {
          if (e.name === 'AbortError') throw e;
          d = { ok: false, error: 'Network error' };
        }
        if (d.ok) { offset = d.received; retries = 0; }
        else if (typeof d.received === 'number' && retries < 5) { offset = d.received; retries++; }
        else if (retries < 5) { retries++; await new Promise(res => setTimeout(res, 1000 * retries)); }
        else throw new Error(d.error || 'Upload failed');
        item.progress = offset / item.file.size; this._update(item);
      }
      item.state = 'verifying'; this._update(item);
      r = await fetch(`/tickets/${tid}/uploads/${item.id}/complete`, { method: 'POST', signal: item.ctrl.signal });
      d = await jsonOrError(r);
      if (!d.ok) { item.id = null; throw new Error(d.error); }
      item.state = 'ready'; item.ctrl = null; this._update(item);
    } catch (e) {
      if (e.name === 'AbortError') return;
      this._fail(item, e.message || 'Upload failed');
    }
  };

  // Upload everything still queued (used once a new ticket has an id).
  Uploader.prototype.uploadAll = async function (ticketId) {
    this.ticketId = ticketId;
    await Promise.all(this.items.filter(i => i.state === 'queued').map(i => this._upload(i)));
  };
  Uploader.prototype.busy = function () { return this.items.some(i => ['checking', 'uploading', 'verifying'].includes(i.state) || (this.ticketId && i.state === 'queued')); };
  Uploader.prototype.hasErrors = function () { return this.items.some(i => i.state === 'error'); };
  Uploader.prototype.count = function () { return this.items.length; };
  Uploader.prototype.readyIds = function () { return this.items.filter(i => i.state === 'ready').map(i => i.id); };
  Uploader.prototype.clear = function () { this.items.forEach(i => i.row.remove()); this.items = []; this.tray.classList.add('hidden'); this.onChange(); };

  // Build the attachment gallery shown inside a message bubble.
  function renderAttachments(list) {
    const wrap = el('div', 'attachments mt-2 flex flex-wrap gap-2');
    (list || []).forEach(a => {
      if (a.kind === 'image') {
        const link = el('a', 'block'); link.href = a.url; link.target = '_blank'; link.rel = 'noopener';
        const img = el('img', 'max-h-60 max-w-full rounded-lg border border-ink-600'); img.loading = 'lazy'; img.alt = a.name; img.src = a.url;
        link.appendChild(img); wrap.appendChild(link);
      } else {
        const box = el('div', 'max-w-full');
        const v = el('video', 'max-h-72 max-w-full rounded-lg border border-ink-600 bg-black');
        v.controls = true; v.preload = 'metadata'; v.src = a.url;
        const cap = el('a', 'block text-[10px] text-gray-400 hover:text-ops-300 mt-1', `🎬 ${a.name}${a.duration ? ' · ' + fmtDur(a.duration) : ''} · ${fmtSize(a.size)}`);
        cap.href = a.url; cap.target = '_blank'; cap.rel = 'noopener';
        box.append(v, cap); wrap.appendChild(box);
      }
    });
    return wrap;
  }

  window.TicketUploads = { Uploader, renderAttachments };
})();
