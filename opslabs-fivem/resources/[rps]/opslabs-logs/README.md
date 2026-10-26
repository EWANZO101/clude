# OPS Logs

Organizes, deduplicates and summarizes FXServer console output. A busy server's console is usually a wall
of interleaved `[resource-name] message` lines, the same warning or stack trace repeating every few
seconds forever, and no way to tell "is this new" from "this again". OPS Logs fixes that for **any**
resource's logs (Lua or JS, including the server's own `citizen-server-impl` lines) — it only relies on
the `[tag] message` shape every FXServer console line already has, so there's nothing to install or wire
up per-script.

Three ways to use it:

1. **In-game**: `/serverlog [tag] [error|warn|info] [count]` — a quick deduplicated recent summary, in
   chat (admins, via the `opslabs.logs` ACE) or the server console.
2. **Web dashboard**: `http://<server-ip>:<http-port>/opslabs-logs/?key=<key>` — live, searchable,
   filterable by resource/tag or level, auto-refreshing. The key is generated once on first start and
   printed to the console (`data/api_key.txt`) — keep it private, it's the only thing gating the dashboard.
3. **Discord**: set `Config.DiscordWebhook` in `config.lua` and get pinged once per *brand-new* distinct
   warning/error — not on every repeat.

There's also a **standalone CLI** (`cli/opslabs-logs-cli.js`) that needs no FXServer, no license, nothing
installed — just plain Node, pointed at any log file:

```
node cli/opslabs-logs-cli.js --file /path/to/fxserver.log                 # one-shot deduplicated summary
node cli/opslabs-logs-cli.js --file /path/to/fxserver.log --follow        # live, like tail -f but organized
node cli/opslabs-logs-cli.js --file ... --level error --tag sna-sync      # filtered
```

## Setup

1. `ensure opslabs-logs` in `server.cfg` (needs `opslabs-license` already ensured and activated — this is
   a licensed OPSHUB module, same as the other OPS resources).
2. Edit `config.json`: set `logFile` to your FXServer console log path (under txAdmin that's
   `txData/<profile>/logs/fxserver.log`), or `journalUnit` to your systemd unit name (e.g. `fivem.service`)
   if your server only logs via journald with no flat file. `config.lua` is separate — Discord webhook URL
   and the in-game admin ACE (it's Lua-only settings; `config.json` is read by the Node/JS half, which
   can't parse Lua syntax — see config.lua's header comment for why there are two files).
3. Restart the resource. The console prints the dashboard URL + key on first start.

## How it works

- **Parsing**: every console line is `[tag] text` — that bracketed tag (the resource name, or
  `citizen-server-impl` for the server itself) is the only thing parsed; everything else is kept verbatim.
- **Severity**: keyword-based (`error`/`uncaught`/`exception` → error; `warn`/`hitch`/`timeout`/`denied` →
  warn; else info) — not per-resource, so it classifies scripts it's never seen before.
- **Dedup**: numbers, hex ids and whitespace are normalized out of each line to build a signature; a
  repeat of the same signature within `dedupeWindowMs` (default 60s, config.json) just bumps a counter on
  the existing entry instead of adding a new row — this is what collapses an error spamming every few
  seconds into one line with a growing `×N`.
- **History**: every ingested line (not just new ones) is appended to `data/logs-YYYY-MM-DD.jsonl`, so the
  full detail survives even though the live dashboard/command only show the deduped view.
- Split across two runtimes by necessity: `server/logtail.js` (real Node, needed for `fs` access to tail
  the log file) does the parsing/storage, `server/main.lua` owns the command and HTTP handler so both stay
  wrapped by `opslabs-license/guard.lua` — the JS side never talks to a player directly.
