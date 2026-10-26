#!/usr/bin/env node
// Standalone CLI version of OPS Logs — same parser/dedup engine as the in-game resource (lib/parser.js),
// but runs anywhere with plain Node: no FXServer, no license, no install. Point it at any server's console
// log (fxserver.log under txAdmin, or wherever you redirect stdout) and get an organized, deduplicated view.
//
// Usage:
//   node opslabs-logs-cli.js --file /path/to/fxserver.log [--follow] [--level error|warn|info]
//                            [--tag sna-sync] [--limit 200] [--json] [--no-color]
//
// With no --follow: reads the whole file once, prints a deduplicated summary (most recent repeat first),
// then exits — good for "what's actually been going wrong". With --follow: behaves like `tail -f`, but
// grouped/deduped/colored as each new line arrives — good for watching a server live.
'use strict';

const fs = require('fs');
const path = require('path');
const { parseLine, LogStore, tailFile, tailJournal } = require(path.join(__dirname, '..', 'lib', 'parser.js'));

function parseArgs(argv) {
  const out = { file: null, journal: null, follow: false, level: null, tag: null, limit: 200, json: false, color: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--file') out.file = argv[++i];
    else if (a === '--journal') { out.journal = argv[++i]; out.follow = true; } // journald has no "whole file" to summarize — always follows
    else if (a === '--follow' || a === '-f') out.follow = true;
    else if (a === '--level') out.level = argv[++i];
    else if (a === '--tag') out.tag = argv[++i];
    else if (a === '--limit') out.limit = parseInt(argv[++i], 10) || 200;
    else if (a === '--json') out.json = true;
    else if (a === '--no-color') out.color = false;
    else if (!out.file && !a.startsWith('--')) out.file = a; // allow a bare path too
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.file && !args.journal) {
  console.error('usage: opslabs-logs-cli.js --file <path-to-log> [--follow] [--level error|warn|info] [--tag <name>] [--json]');
  console.error('   or: opslabs-logs-cli.js --journal <systemd-unit>   (e.g. --journal fivem.service — follows journalctl, no file needed)');
  process.exit(1);
}
if (args.file && !fs.existsSync(args.file) && !args.follow) {
  console.error(`no such file: ${args.file}`);
  process.exit(1);
}

const COLOR = args.color && process.stdout.isTTY;
const RESET = COLOR ? '\x1b[0m' : '';
const COLORS = { error: COLOR ? '\x1b[31m' : '', warn: COLOR ? '\x1b[33m' : '', info: COLOR ? '\x1b[90m' : '' };
const TAG_COLOR = COLOR ? '\x1b[36m' : '';
const BOLD = COLOR ? '\x1b[1m' : '';

function matches(e) {
  if (args.level && e.level !== args.level) return false;
  if (args.tag && (e.tag || '') !== args.tag) return false;
  return true;
}

function printEntry(e) {
  if (args.json) {
    console.log(JSON.stringify({ at: e.lastAt, tag: e.tag, level: e.level, text: e.lastText, count: e.count }));
    return;
  }
  const time = new Date(e.lastAt).toTimeString().slice(0, 8);
  const countTxt = e.count > 1 ? `${BOLD} ×${e.count}${RESET}` : '';
  const tag = (e.tag || '(server)').padEnd(22).slice(0, 22);
  console.log(`${time} ${TAG_COLOR}${tag}${RESET} ${COLORS[e.level] || ''}${e.lastText}${RESET}${countTxt}`);
}

const store = new LogStore({ capacity: Math.max(args.limit, 2000), dedupeWindowMs: args.follow ? 60000 : Infinity });

if (!args.follow) {
  const lines = fs.readFileSync(args.file, 'utf8').split('\n');
  for (const line of lines) {
    const parsed = parseLine(line);
    if (parsed) store.ingest(parsed, Date.now());
  }
  const rows = store.recent({ tag: args.tag, level: args.level, limit: args.limit }).reverse();
  if (!rows.length) {
    console.log('(nothing matched)');
  } else {
    for (const e of rows) printEntry(e);
    console.log(`\n${rows.length} distinct line(s) shown (deduped from ${lines.length} raw lines)`);
  }
  process.exit(0);
}

function onFollowedLine(raw) {
  const parsed = parseLine(raw);
  if (!parsed) return;
  const result = store.ingest(parsed, Date.now());
  if (result && matches(result.entry)) printEntry(result.entry);
}

if (args.journal) {
  console.error(`following journalctl -u ${args.journal} (Ctrl+C to stop)…`);
  tailJournal(args.journal, onFollowedLine, { onError: (e) => { console.error(`journalctl failed: ${e.message}`); process.exit(1); } });
} else {
  console.error(`watching ${args.file} (Ctrl+C to stop)…`);
  tailFile(args.file, onFollowedLine, { intervalMs: 500, fromStart: false });
}
