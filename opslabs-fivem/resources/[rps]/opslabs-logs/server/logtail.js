// OPS Logs — tailing/storage half, running in the resource's JS runtime (chosen because reading the log
// file needs real fs access, which the Lua side doesn't have). Talks to server/main.lua — which owns the
// OPSHUB-guarded command and HTTP handler — only through same-resource exports (never TriggerEvent/
// AddEventHandler across the Lua/JS boundary), so every player/admin-facing entry point stays wrapped by
// opslabs-license/guard.lua.
const fs = require('fs');
const path = require('path');
const RESOURCE_DIR = GetResourcePath(GetCurrentResourceName());
// a plain relative require (e.g. '../lib/parser.js') resolves against this resource's synthetic entry
// script at the resource root, not against server/logtail.js's own folder - one '..' too many, and
// "Cannot find module" either way once any resource's folder structure doesn't happen to line up by luck.
// An absolute path built from GetResourcePath sidesteps that entirely.
const { parseLine, LogStore, tailFile, tailJournal, normalize } = require(path.join(RESOURCE_DIR, 'lib', 'parser.js'));

const DATA_DIR = path.join(RESOURCE_DIR, 'data');
try { fs.mkdirSync(DATA_DIR, { recursive: true }); } catch (e) { /* already exists */ }

// config.lua's `Config` global only exists in the Lua runtime (shared_script still only parses as Lua) —
// this half reads its own settings from config.json instead. See config.lua's header comment.
const DEFAULT_CFG = { logFile: '', extraLogFiles: [], journalUnit: '', dedupeWindowMs: 60000, capacity: 2000, discordMinLevel: 'warn' };
let Cfg = DEFAULT_CFG;
try {
  Cfg = Object.assign({}, DEFAULT_CFG, JSON.parse(fs.readFileSync(path.join(RESOURCE_DIR, 'config.json'), 'utf8')));
} catch (e) {
  console.log(`^1[opslabs-logs] could not read/parse config.json (${e.message}) — using defaults (nothing will be tailed)^7`);
}

const store = new LogStore({
  capacity: Cfg.capacity || 2000,
  dedupeWindowMs: Cfg.dedupeWindowMs || 60000,
});

const knownSignatures = new Set(); // signatures seen since boot (seeded from today's history) — for "truly new" alerts
let lastAlertAt = 0;
const ALERT_MIN_GAP_MS = 5000; // don't let a burst of new distinct errors spam Discord
let pendingAlerts = []; // drained by main.lua's PopPendingAlerts poll loop

function historyFile(at = Date.now()) {
  const d = new Date(at).toISOString().slice(0, 10);
  return path.join(DATA_DIR, `logs-${d}.jsonl`);
}

function appendHistory(entry, at) {
  const line = JSON.stringify({ at, tag: entry.tag, level: entry.level, text: entry.lastText }) + '\n';
  fs.appendFile(historyFile(at), line, () => {});
}

function seedKnownSignatures() {
  try {
    const lines = fs.readFileSync(historyFile(), 'utf8').split('\n');
    for (const line of lines) {
      if (!line) continue;
      try {
        const rec = JSON.parse(line);
        knownSignatures.add(`${rec.tag || ''}|${normalize(rec.text || '')}`);
      } catch (e) { /* skip a corrupt line */ }
    }
  } catch (e) { /* no history yet today */ }
}
seedKnownSignatures();

function levelRank(l) { return l === 'error' ? 2 : l === 'warn' ? 1 : 0; }
const minAlertRank = levelRank(Cfg.discordMinLevel || 'warn');

function onLine(raw) {
  const parsed = parseLine(raw);
  if (!parsed) return;
  const at = Date.now();
  const result = store.ingest(parsed, at);
  if (!result) return;
  appendHistory(result.entry, at);

  if (result.isNew && levelRank(parsed.level) >= minAlertRank) {
    const sig = result.entry.sig;
    if (!knownSignatures.has(sig)) {
      knownSignatures.add(sig);
      if (at - lastAlertAt >= ALERT_MIN_GAP_MS) {
        lastAlertAt = at;
        pendingAlerts.push({ tag: parsed.tag || '(server)', level: parsed.level, text: parsed.text, at });
      }
    }
  }
}

const files = [Cfg.logFile, ...(Cfg.extraLogFiles || [])].filter((f) => f && f.length > 0);
const stoppers = [];
for (const f of files) {
  if (!fs.existsSync(f)) {
    console.log(`^3[opslabs-logs] log file not found yet, will keep watching: ${f}^7`);
  }
  stoppers.push(tailFile(f, onLine, { intervalMs: 1000, fromStart: false }));
}
if (files.length) console.log(`^2[opslabs-logs] watching ${files.length} log file(s)^7`);

// Some deployments never write a flat console log at all — e.g. a plain systemd unit with no txAdmin file
// logging configured, only journald. Cfg.journalUnit covers that case (and can run alongside Cfg.logFile).
if (Cfg.journalUnit && Cfg.journalUnit.length > 0) {
  stoppers.push(tailJournal(Cfg.journalUnit, onLine, {
    onError: (e) => console.log(`^1[opslabs-logs] journalctl -u ${Cfg.journalUnit} failed (${e.message}) — this runtime may not allow spawning processes; file-based logFile still works^7`),
  }));
  console.log(`^2[opslabs-logs] following journalctl -u ${Cfg.journalUnit} (watch the console for an error above if this runtime can't spawn processes)^7`);
}

if (files.length === 0 && !Cfg.journalUnit) {
  console.log('^3[opslabs-logs] nothing configured — set logFile (a flat console log) or journalUnit (a systemd unit name) in config.json.^7');
}

on('onResourceStop', (resName) => {
  if (resName !== GetCurrentResourceName()) return;
  for (const stop of stoppers) stop();
});

exports('GetRecent', (opts) => store.recent(opts || {}));
exports('GetStats', () => store.tagStats());
exports('GetTags', () => store.tagStats().map((s) => s.tag));
exports('PopPendingAlerts', () => {
  const out = pendingAlerts;
  pendingAlerts = [];
  return out;
});
