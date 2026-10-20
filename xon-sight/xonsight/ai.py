"""Thin wrapper around the Claude API for Xon Sight's AI features - Draft
One / Brief One / Axon Assistant analogs (see README.md).

Every public function returns an (ok: bool, ...) tuple so callers never
need to catch SDK exceptions directly. If ANTHROPIC_API_KEY isn't set,
everything short-circuits to ok=False with a "not configured" message
instead of erroring.

Nothing here is CJIS-compliant or carries any other compliance
certification - that's a real audit this app hasn't gone through, and
nothing in this module or its UI claims otherwise. Every generated draft,
brief, or BOLO is meant for a human to review before it's used anywhere;
this portal never submits or publishes anything on its own.
"""

import json

from flask import current_app

MAX_TOKENS_DEFAULT = 4096


def _client():
    api_key = current_app.config.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None
    import anthropic

    return anthropic.Anthropic(api_key=api_key)


def _call(system, messages, effort="medium", max_tokens=MAX_TOKENS_DEFAULT):
    client = _client()
    if client is None:
        return False, "AI features aren't configured - set ANTHROPIC_API_KEY in .env."

    import anthropic

    try:
        response = client.messages.create(
            model=current_app.config.get("AI_MODEL", "claude-opus-5"),
            max_tokens=max_tokens,
            system=system,
            thinking={"type": "adaptive"},
            output_config={"effort": effort},
            messages=messages,
        )
    except anthropic.AuthenticationError:
        return False, "AI request failed: the configured ANTHROPIC_API_KEY was rejected."
    except anthropic.APIStatusError as e:
        return False, f"AI request failed ({e.status_code}): {e.message}"
    except anthropic.APIConnectionError:
        return False, "AI request failed: couldn't reach the Anthropic API."

    if response.stop_reason == "refusal":
        return False, "The model declined to generate this."

    text = "".join(block.text for block in response.content if block.type == "text")
    return True, text.strip()


def draft_report(evidence, notes):
    """Draft One analog - draft a report narrative from an evidence item's
    transcript/caption/notes."""
    system = (
        "You draft the narrative section of a police incident report from "
        "bodycam evidence metadata for a roleplay server's records system. "
        "Write in first person past tense as the reporting officer, plain "
        "factual prose, no speculation beyond what's in the material given. "
        "If the material is too thin to draft from, say so plainly instead "
        "of inventing details. This is a draft for a human to review and "
        "edit before it's used anywhere - do not claim it is final."
    )
    notes_text = "\n".join(f"- {n['author'] or 'Unknown'}: {n['body']}" for n in notes) or "(none)"
    user_content = (
        f"Officer: {evidence.get('submitterName') or 'Unknown'}\n"
        f"Caption: {evidence.get('caption') or '(none)'}\n"
        f"Recorded at: {evidence.get('createdAt')}\n\n"
        f"Transcript:\n{evidence.get('transcript') or '(no transcript available)'}\n\n"
        f"Case notes:\n{notes_text}\n\n"
        "Draft the narrative section of the report."
    )
    return _call(system, [{"role": "user", "content": user_content}], effort="medium")


def brief_video(evidence, notes, markers):
    """Brief One analog - summarize + flag likely evidentiary milestones.
    Returns (ok, summary: str, milestones: list[{"label", "note"}])."""
    system = (
        "You summarize bodycam evidence for an investigator skimming many "
        "videos. From the transcript/notes/markers given (never guessing "
        "beyond them), write a short summary, then list notable moments "
        "that might be evidentiary milestones (e.g. a Miranda warning, a "
        "weapon mentioned, a use-of-force moment, an admission). Respond "
        'ONLY with JSON: {"summary": str, "milestones": '
        '[{"label": str, "note": str}]}. If there is not enough material, '
        "return an empty milestones list and say so in summary."
    )
    notes_text = "\n".join(f"- {n['author'] or 'Unknown'}: {n['body']}" for n in notes) or "(none)"
    markers_text = (
        "\n".join(f"- {m['timestampSeconds']:.0f}s: {m['label']}" for m in markers) or "(none)"
    )
    user_content = (
        f"Officer: {evidence.get('submitterName') or 'Unknown'}\n"
        f"Caption: {evidence.get('caption') or '(none)'}\n\n"
        f"Transcript:\n{evidence.get('transcript') or '(no transcript available)'}\n\n"
        f"Existing case notes:\n{notes_text}\n\n"
        f"Existing markers:\n{markers_text}"
    )
    ok, text = _call(system, [{"role": "user", "content": user_content}], effort="medium")
    if not ok:
        return False, text, []

    try:
        parsed = json.loads(text)
        return True, parsed.get("summary", ""), parsed.get("milestones", [])
    except (ValueError, AttributeError, TypeError):
        return True, text, []


def assistant_reply(message, history, context):
    """Axon Assistant analog - general Q&A over recent evidence/case/BOLO
    context for this server. Plain Claude call, nothing certified."""
    system = (
        "You are an operations assistant inside a FiveM roleplay server's "
        "evidence portal (Xon Sight). You help whoever is on shift look up "
        "recent evidence, cases, and BOLOs, and answer general "
        "policy/procedure questions for the server. You are not a "
        "certified or compliance-audited system - say so plainly if asked "
        "about compliance. Be concise. If the context given doesn't answer "
        "the question, say what you don't have rather than guessing."
    )
    context_text = json.dumps(context, indent=2)
    messages = list(history) + [
        {
            "role": "user",
            "content": f"Context (recent server data):\n{context_text}\n\nQuestion: {message}",
        }
    ]
    return _call(system, messages, effort="low", max_tokens=2048)


def draft_bolo(notes):
    """Turn rough notes into a formatted BOLO subject + details. Always
    requires an explicit human "Publish" click afterward."""
    system = (
        "Turn rough notes into a formatted BOLO (Be On The Lookout) alert "
        "for a FiveM roleplay server. Respond ONLY with JSON: "
        '{"subject": str (one line), "details": str (a short paragraph)}.'
    )
    ok, text = _call(system, [{"role": "user", "content": notes}], effort="low", max_tokens=512)
    if not ok:
        return False, {"subject": "", "details": text}
    try:
        parsed = json.loads(text)
        return True, {"subject": parsed.get("subject", ""), "details": parsed.get("details", "")}
    except (ValueError, AttributeError, TypeError):
        return True, {"subject": "", "details": text}
