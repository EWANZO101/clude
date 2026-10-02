"""
Local Admin AI — error assistance (Part 2, spec section 14).

Deliberately does the actual grouping/counting in plain Python first,
never trusts the language model to get arithmetic on error lists
right, and never requires a model to be configured at all -- explain()
always returns a correct, readable summary on its own. If a local
model *is* configured, its output is used only to smooth the wording,
with the deterministic summary handed to it as ground truth context
(same pattern as chat's retrieval-then-generate), and any model
failure silently falls back to the deterministic text rather than
erroring the request.
"""
from __future__ import annotations

import re
from collections import Counter

from app import ai_engine
from app.ai_models import AISettings


def _reason_bucket(error_line: str) -> str:
    """Collapses "Row 4 (Widget): SKU 'W-1' already in use — skipped."
    and "Row 9 (Gadget): SKU 'G-2' already in use — skipped." into the
    same bucket ("SKU already in use") so 50 near-identical row errors
    read as one line with a count, not fifty."""
    text = error_line
    text = re.sub(r"^Row \d+(\s*\([^)]*\))?:\s*", "", text)  # strip "Row N (name): "
    text = re.sub(r"'[^']*'", "'…'", text)  # blank out the specific value quoted
    text = text.strip().rstrip(".")
    return text


def summarize_import_result(result: dict) -> str:
    created = result.get("created", 0)
    updated = result.get("updated", 0)
    errors = result.get("errors", []) or []

    parts = []
    if created:
        parts.append(f"{created} row{'s' if created != 1 else ''} created")
    if updated:
        parts.append(f"{updated} row{'s' if updated != 1 else ''} updated")
    if not parts:
        parts.append("no rows were created or updated")

    if not errors:
        return f"Import finished cleanly: {', '.join(parts)}, no errors."

    buckets = Counter(_reason_bucket(e) for e in errors)
    error_lines = [
        f"{count} row{'s' if count != 1 else ''} failed because {reason}"
        for reason, count in buckets.most_common()
    ]
    return (
        f"Import finished: {', '.join(parts)}. "
        f"{len(errors)} row{'s' if len(errors) != 1 else ''} failed:\n"
        + "\n".join(f"- {line}" for line in error_lines)
    )


def summarize_sync_logs(logs: list[dict]) -> str:
    if not logs:
        return "No sync activity recorded yet."
    by_status = Counter(l.get("status") for l in logs)
    latest = logs[0]
    parts = [f"{count} {status}" for status, count in by_status.items()]
    summary = f"Last {len(logs)} sync attempts: {', '.join(parts)}."
    if latest.get("status") == "error" and latest.get("message"):
        summary += f" Most recent error: {latest['message']}"
    elif latest.get("status") == "conflict" and latest.get("message"):
        summary += f" Most recent conflict: {latest['message']}"
    return summary


SUMMARIZERS = {
    "import_items": summarize_import_result,
    "import_tools": summarize_import_result,
    "sync_logs": summarize_sync_logs,
}


def explain(source: str, data) -> str:
    fn = SUMMARIZERS.get(source)
    if not fn:
        raise ValueError(f"Unknown explain source '{source}'.")
    deterministic = fn(data)

    settings = AISettings.get()
    if not settings.enabled or ai_engine.status(settings)["state"] != "ready":
        return deterministic

    try:
        from flask import current_app
        polished = ai_engine.generate(
            settings,
            conversation_messages=[{
                "sender": "user",
                "content": "Rephrase the following result plainly for someone operating the "
                            "kiosk, in at most three sentences. Do not invent numbers or reasons "
                            "beyond what's given:\n\n" + deterministic,
            }],
            context_snippets=[],
            llama_server_port=current_app.config.get("LLAMA_SERVER_PORT", 8422),
        )
        return polished or deterministic
    except ai_engine.AIEngineError:
        return deterministic
