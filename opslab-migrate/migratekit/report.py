"""Generate HTML / JSON / TXT migration reports."""

from __future__ import annotations

import json
import time
from pathlib import Path

REPORT_DIR = Path("reports")

_HTML_TMPL = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>Migration Report — {generated}</title>
<style>
  body {{ font-family: -apple-system, Segoe UI, Roboto, sans-serif;
         margin: 2rem auto; max-width: 960px; color: #1f2937; }}
  h1 {{ border-bottom: 3px solid #2563eb; padding-bottom: .4rem; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1rem 0; }}
  th, td {{ border: 1px solid #d1d5db; padding: .5rem .75rem;
            text-align: left; font-size: .9rem; }}
  th {{ background: #f3f4f6; }}
  .pass {{ color: #059669; font-weight: 600; }}
  .fail {{ color: #dc2626; font-weight: 600; }}
  .warn {{ color: #d97706; font-weight: 600; }}
  .summary {{ display: flex; gap: 1rem; flex-wrap: wrap; margin: 1rem 0; }}
  .card {{ background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px;
           padding: 1rem 1.5rem; min-width: 140px; }}
  .card b {{ font-size: 1.6rem; display: block; }}
  code {{ background: #f3f4f6; padding: 1px 5px; border-radius: 4px; }}
</style></head><body>
<h1>OpsLab Migrate — Report</h1>
<p>Generated {generated} &middot; Duration {duration} &middot;
Source <code>{source}</code> &rarr; Destination <code>{destination}</code></p>
<div class="summary">
  <div class="card"><b>{n_projects}</b>Projects</div>
  <div class="card"><b>{n_databases}</b>Databases</div>
  <div class="card"><b class="pass">{n_ok}</b>Succeeded</div>
  <div class="card"><b class="fail">{n_failed}</b>Failed</div>
  <div class="card"><b class="warn">{n_warnings}</b>Warnings</div>
</div>
<h2>Projects</h2>
<table>
<tr><th>Project</th><th>Framework</th><th>Status</th><th>Archive size</th>
<th>SHA-256</th><th>Transfer speed</th><th>Checks</th></tr>
{project_rows}
</table>
<h2>Verification detail</h2>
{verify_sections}
<h2>Warnings &amp; failures</h2>
<ul>{issue_items}</ul>
<h2>Healing actions</h2>
<ul>{heal_items}</ul>
<p style="color:#6b7280;font-size:.8rem">Disk free on destination after
migration: {disk_free} MB</p>
</body></html>
"""


def _fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def _fmt_duration(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


class Reporter:
    def __init__(self, summary: dict):
        """summary keys: source, destination, started_ts, projects (list of
        per-project dicts), heal_actions, warnings, disk_free_mb."""
        self.s = summary

    def write_all(self) -> dict[str, Path]:
        REPORT_DIR.mkdir(exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        paths = {
            "json": REPORT_DIR / f"migration-{stamp}.json",
            "html": REPORT_DIR / f"migration-{stamp}.html",
            "txt": REPORT_DIR / f"migration-{stamp}.txt",
        }
        paths["json"].write_text(
            json.dumps(self.s, indent=2, default=str), encoding="utf-8")
        paths["html"].write_text(self._html(), encoding="utf-8")
        paths["txt"].write_text(self._txt(), encoding="utf-8")
        return paths

    # ------------------------------------------------------------- html

    def _html(self) -> str:
        s = self.s
        projects = s.get("projects", [])
        rows, verify_sections, issues = [], [], []
        n_db = n_ok = n_failed = 0
        for p in projects:
            checks = p.get("checks", [])
            ok = p.get("status") == "done"
            n_ok += ok
            n_failed += (not ok)
            n_db += len(p.get("databases", []))
            passed = sum(1 for c in checks if c["passed"])
            speed = ""
            if p.get("transfer_seconds") and p.get("size"):
                speed = _fmt_bytes(
                    p["size"] / max(p["transfer_seconds"], 0.1)) + "/s"
            rows.append(
                f"<tr><td>{p['name']}</td><td>{p.get('framework','')}</td>"
                f"<td class='{'pass' if ok else 'fail'}'>"
                f"{p.get('status','')}</td>"
                f"<td>{_fmt_bytes(p.get('size', 0))}</td>"
                f"<td><code>{p.get('sha256','')[:16]}…</code></td>"
                f"<td>{speed}</td>"
                f"<td>{passed}/{len(checks)}</td></tr>")
            check_rows = "".join(
                f"<tr><td>{c['name']}</td>"
                f"<td class='{'pass' if c['passed'] else 'fail'}'>"
                f"{'PASS' if c['passed'] else 'FAIL'}</td>"
                f"<td>{c.get('detail','')}</td></tr>"
                for c in checks)
            verify_sections.append(
                f"<h3>{p['name']}</h3><table>"
                f"<tr><th>Check</th><th>Result</th><th>Detail</th></tr>"
                f"{check_rows}</table>")
            for c in checks:
                if not c["passed"]:
                    issues.append(
                        f"<li class='fail'>{p['name']}: {c['name']} — "
                        f"{c.get('detail','')}</li>")
        for w in s.get("warnings", []):
            issues.append(f"<li class='warn'>{w}</li>")
        heal = "".join(f"<li>{a}</li>" for a in s.get("heal_actions", [])) \
            or "<li>None required</li>"
        return _HTML_TMPL.format(
            generated=time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
            duration=_fmt_duration(s.get("duration_seconds", 0)),
            source=s.get("source", "?"), destination=s.get("destination", "?"),
            n_projects=len(projects), n_databases=n_db, n_ok=n_ok,
            n_failed=n_failed, n_warnings=len(s.get("warnings", [])),
            project_rows="".join(rows) or
            "<tr><td colspan=7>No projects</td></tr>",
            verify_sections="".join(verify_sections) or "<p>None</p>",
            issue_items="".join(issues) or "<li>None</li>",
            heal_items=heal,
            disk_free=s.get("disk_free_mb", "?"))

    # -------------------------------------------------------------- txt

    def _txt(self) -> str:
        s = self.s
        lines = [
            "OPSLAB MIGRATE — SUMMARY",
            "=" * 50,
            f"Source:       {s.get('source')}",
            f"Destination:  {s.get('destination')}",
            f"Duration:     {_fmt_duration(s.get('duration_seconds', 0))}",
            "",
        ]
        for p in s.get("projects", []):
            checks = p.get("checks", [])
            passed = sum(1 for c in checks if c["passed"])
            lines += [
                f"[{'OK' if p.get('status') == 'done' else 'FAIL'}] "
                f"{p['name']} ({p.get('framework', '?')})",
                f"     archive: {_fmt_bytes(p.get('size', 0))}  "
                f"sha256: {p.get('sha256', '')[:16]}…",
                f"     checks:  {passed}/{len(checks)} passed",
            ]
            for c in checks:
                if not c["passed"]:
                    lines.append(f"       FAIL {c['name']}: "
                                 f"{c.get('detail', '')}")
        if s.get("warnings"):
            lines += ["", "WARNINGS:"] + [f"  - {w}" for w in s["warnings"]]
        if s.get("heal_actions"):
            lines += ["", "HEALING ACTIONS:"] + \
                     [f"  - {a}" for a in s["heal_actions"]]
        return "\n".join(lines) + "\n"
