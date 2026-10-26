// OPS Logs — shared parsing/dedup engine. Pure Node (fs only), no FXServer natives, so the exact same
// code runs inside the FXServer resource (server/logtail.js) and the standalone CLI (cli/opslabs-logs-cli.js).
//
// FXServer console lines all look like "[   some-tag  ] message text", whatever the resource (Lua, JS,
// the server itself). That bracketed tag is the only universal structure any script's log has — so parsing
// keys off it instead of guessing per-framework formats.
'use strict';

const fs = require('fs');

const TAG_RE = /^\[\s*([^\]]*?)\s*\]\s?(.*)$/;
// eslint-disable-next-line no-control-regex
const ANSI_RE = /\x1b\[[0-9;]*[a-zA-Z]/g;

/** Strip ANSI/SGR color escapes. FXServer colors its console with these (its own ^1/^2/^3 markup gets
 * translated to real ANSI when written to something that looks like a terminal) — a plain file-redirected
 * log usually doesn't have them, but journalctl output and anything captured via a pty (script, tee from
 * a terminal, etc.) does, and they land right before the "[tag]" bracket, breaking TAG_RE. Always strip
 * first so parsing behaves the same regardless of how the line was captured. */
function stripAnsi(s) {
  return s.replace(ANSI_RE, '');
}

// Checked in order; first match wins. Deliberately keyword-based (not per-resource) so it works for scripts
// this was never taught about.
const LEVEL_RULES = [
  { level: 'error', re: /\b(uncaught|unhandled|exception|fatal|panic|segfault|stack ?trace|traceback)\b/i },
  { level: 'error', re: /\berror\b/i },
  { level: 'warn', re: /\b(warn(ing)?s?|hitch|deprecat\w*|time[\s-]?out|retry(ing)?|denied|refused|could not|failed to)\b/i },
  { level: 'warn', re: /\bfailed\b/i },
];

function classify(text) {
  for (const rule of LEVEL_RULES) if (rule.re.test(text)) return rule.level;
  return 'info';
}

/** Parse one raw console line into { tag, text, level }, or null for a blank line. */
function parseLine(raw) {
  const line = stripAnsi(raw.replace(/\r$/, ''));
  if (!line.trim()) return null;
  const m = TAG_RE.exec(line);
  if (!m) return { tag: null, text: line, level: classify(line) };
  const tag = m[1].trim() || null;
  const text = m[2];
  return { tag, text, level: classify(text) };
}

/** Collapse the parts of a message that change every occurrence (numbers, hex ids, durations) so repeats
 * of "the same" error — e.g. a hitch warning with a different millisecond count each time — share one signature. */
function normalize(text) {
  return text
    .replace(/0x[0-9a-f]+/gi, '0xN')
    .replace(/\d+/g, 'N')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 240);
}

function signatureOf(tag, text) {
  return `${tag || ''}|${normalize(text)}`;
}

/** In-memory ring buffer of grouped+deduped log entries, plus per-tag stats. */
class LogStore {
  constructor({ capacity = 2000, dedupeWindowMs = 60000 } = {}) {
    this.capacity = capacity;
    this.dedupeWindowMs = dedupeWindowMs;
    this.entries = [];       // ring buffer, oldest first
    this.active = new Map(); // signature -> entry, while still inside its dedupe window
    this.stats = new Map();  // tag -> { tag, count, errors, warns, lastAt }
    this.seq = 0;
  }

  _touchStats(tag, level, at) {
    const key = tag || '(server)';
    const s = this.stats.get(key) || { tag: key, count: 0, errors: 0, warns: 0, lastAt: 0 };
    s.count++;
    if (level === 'error') s.errors++;
    if (level === 'warn') s.warns++;
    s.lastAt = at;
    this.stats.set(key, s);
  }

  /** Feed one parsed line in. Returns { entry, isNew } — isNew means a fresh signature (or one whose
   * dedupe window had already lapsed), not "never seen before ever" (callers wanting that should track
   * signatures themselves, e.g. for first-ever-seen alerting — see server/logtail.js). */
  ingest(parsed, at = Date.now()) {
    if (!parsed) return null;
    const { tag, text, level } = parsed;
    this._touchStats(tag, level, at);
    const sig = signatureOf(tag, text);
    const existing = this.active.get(sig);
    if (existing && at - existing.lastAt <= this.dedupeWindowMs) {
      existing.count++;
      existing.lastAt = at;
      existing.lastText = text;
      return { entry: existing, isNew: false };
    }
    const entry = { id: ++this.seq, sig, tag, level, firstText: text, lastText: text, count: 1, firstAt: at, lastAt: at };
    this.active.set(sig, entry);
    this.entries.push(entry);
    if (this.entries.length > this.capacity) {
      const dropped = this.entries.shift();
      if (this.active.get(dropped.sig) === dropped) this.active.delete(dropped.sig);
    }
    return { entry, isNew: true };
  }

  /** Most recent entries first, optionally filtered. */
  recent({ tag, level, q, limit = 200 } = {}) {
    const needle = q ? q.toLowerCase() : null;
    const out = [];
    for (let i = this.entries.length - 1; i >= 0 && out.length < limit; i--) {
      const e = this.entries[i];
      if (tag && (e.tag || '') !== tag) continue;
      if (level && e.level !== level) continue;
      if (needle && !((e.lastText || '').toLowerCase().includes(needle) || (e.tag || '').toLowerCase().includes(needle))) continue;
      out.push(e);
    }
    return out;
  }

  tagStats() {
    return Array.from(this.stats.values()).sort((a, b) => b.lastAt - a.lastAt);
  }
}

/** Tail a growing (and occasionally truncated/rotated) text file, calling onLine for each complete line
 * from the current end onward. Uses polling (fs.watchFile) rather than fs.watch — far more reliable on
 * Docker/overlay filesystems, which is how most FXServer boxes run. Returns a stop() function. */
function tailFile(path, onLine, { intervalMs = 1000, fromStart = false } = {}) {
  let pos = 0;
  let buf = '';
  let closed = false;

  function readNew() {
    fs.stat(path, (err, st) => {
      if (closed || err) return;
      if (st.size < pos) pos = 0; // truncated or rotated — start over
      if (st.size === pos) return;
      const stream = fs.createReadStream(path, { start: pos, end: st.size - 1, encoding: 'utf8' });
      stream.on('data', (chunk) => {
        buf += chunk;
        const lines = buf.split('\n');
        buf = lines.pop();
        for (const line of lines) onLine(line);
      });
      stream.on('end', () => { pos = st.size; });
      stream.on('error', () => {});
    });
  }

  fs.stat(path, (err, st) => {
    if (err) { pos = 0; } else { pos = fromStart ? 0 : st.size; }
    readNew();
  });
  fs.watchFile(path, { interval: intervalMs }, readNew);

  return function stop() {
    closed = true;
    fs.unwatchFile(path, readNew);
  };
}

/** Follow a systemd unit's journal (for setups where the console only exists via journald — no flat log
 * file at all, e.g. a plain `ExecStart=fxserver ...` systemd unit with no txAdmin file logging configured).
 * Spawns `journalctl -u <unit> -f -n 0 -o cat` (so each line is already bare "[tag] message", same shape
 * as a file line) and respawns it if it ever exits. Requires the `child_process` module, so Node only —
 * never called from inside the game-sandboxed FXServer Lua runtime. Returns a stop() function. */
function tailJournal(unit, onLine, { restartDelayMs = 2000, onError } = {}) {
  let spawn, readline;
  try {
    ({ spawn } = require('child_process'));
    readline = require('readline');
  } catch (e) {
    // Some embedded JS runtimes (this is reached from inside FXServer's resource sandbox, not just plain
    // Node) may not expose child_process. Fail soft — file-based tailing and everything else still works.
    if (onError) onError(e);
    return function stop() {};
  }
  let closed = false;
  let child = null;

  function start() {
    if (closed) return;
    try {
      child = spawn('journalctl', ['-u', unit, '-f', '-n', '0', '-o', 'cat'], { stdio: ['ignore', 'pipe', 'ignore'] });
    } catch (e) {
      if (onError) onError(e);
      return;
    }
    const rl = readline.createInterface({ input: child.stdout });
    rl.on('line', onLine);
    child.on('exit', () => {
      if (!closed) setTimeout(start, restartDelayMs);
    });
    child.on('error', (e) => {
      if (onError) onError(e);
      if (!closed) setTimeout(start, restartDelayMs);
    });
  }
  start();

  return function stop() {
    closed = true;
    if (child) child.kill();
  };
}

module.exports = { parseLine, classify, normalize, signatureOf, stripAnsi, LogStore, tailFile, tailJournal };
