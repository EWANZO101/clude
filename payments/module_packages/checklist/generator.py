"""Rule-based checklist generator: turns pasted text / rough ideas into
structured tasks. No external AI dependency — deterministic and offline.
Swappable for an AI-backed generator once the AI service (Part 9) lands;
same output shape either way: list[dict(title, category, priority, estimated_minutes)].
"""
import re

CATEGORY_KEYWORDS = {
    "auth": ["login", "password", "authentication", "signup", "register", "logout", "2fa", "two-factor"],
    "database": ["model", "table", "schema", "migration", "database"],
    "ui": ["page", "screen", "button", "form", "template", "design", "layout"],
    "api": ["endpoint", "api", "route"],
    "testing": ["test", "tests"],
    "email": ["email", "notification", "reminder"],
    "security": ["security", "encrypt", "csrf", "token"],
}

TIME_HINTS = {
    "testing": 30,
    "database": 20,
    "ui": 25,
    "api": 20,
    "auth": 25,
}

STOPWORDS_START = re.compile(r"^(add|create|build|implement|make|set up|setup|allow|support)\s+", re.I)


def _guess_category(text):
    lowered = text.lower()
    for category, keywords in CATEGORY_KEYWORDS.items():
        if any(k in lowered for k in keywords):
            return category
    return "general"


def _guess_priority(text):
    lowered = text.lower()
    if any(w in lowered for w in ["critical", "must", "required", "security", "password"]):
        return "high"
    if any(w in lowered for w in ["nice to have", "optional", "later"]):
        return "low"
    return "medium"


def _split_line_into_tasks(line):
    """Splits a single input line on 'and'/commas into separate atomic tasks
    when it looks like a compound instruction, e.g.
    'Add user authentication and password reset.' -> two tasks."""
    line = line.strip().rstrip(".")
    if not line:
        return []

    # Already a checklist-style line ("- foo", "- [ ] foo", "* foo", "1. foo")
    line = re.sub(r"^[-*]\s*(\[\s?\]\s*)?", "", line)
    line = re.sub(r"^\d+[\.\)]\s*", "", line)

    parts = re.split(r"\s+and\s+", line, flags=re.I)
    tasks = []
    for part in parts:
        part = part.strip()
        if not part:
            continue
        # Split further on commas if it reads like a list of nouns
        if "," in part and len(part.split(",")) > 1 and len(part) < 120:
            sub_parts = [p.strip() for p in part.split(",") if p.strip()]
            tasks.extend(sub_parts)
        else:
            tasks.append(part)
    return tasks


def generate_checklist(raw_text):
    """Returns list[dict] ready for saving as ChecklistTask rows."""
    if not raw_text or not raw_text.strip():
        return []

    lines = [l for l in raw_text.splitlines() if l.strip()]
    generated = []
    seen = set()

    for line in lines:
        for fragment in _split_line_into_tasks(line):
            title = fragment[0].upper() + fragment[1:] if fragment else fragment
            key = title.lower()
            if key in seen:
                continue
            seen.add(key)
            category = _guess_category(title)
            generated.append({
                "title": title,
                "category": category,
                "priority": _guess_priority(title),
                "estimated_minutes": TIME_HINTS.get(category, 15),
            })

    return generated
