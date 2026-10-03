"""
KnowledgeBase — persistent store for scraped content, Q&A pairs,
and user-submitted corrections.
"""

import json
import os
import logging
from datetime import datetime
from config import Config

log = logging.getLogger("cfrp_bot.knowledge_base")


def _load(path: str) -> dict:
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def _save(path: str, data: dict):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


class KnowledgeBase:
    def __init__(self):
        self._kb       = _load(Config.KNOWLEDGE_FILE)
        self._feedback = _load(Config.FEEDBACK_FILE)

        # Ensure top-level keys exist
        self._kb.setdefault("pages",       {})   # url -> scraped text
        self._kb.setdefault("channels",    {})   # channel_id -> summary
        self._kb.setdefault("corrections", {})   # question -> corrected answer

        # Flat doc list — used by status command for a document count
        self._docs = (
            list(self._kb["pages"].values()) +
            list(self._kb["channels"].values()) +
            list(self._kb["corrections"].values())
        )

    # ── Context building ───────────────────────────────────────────────────────

    def build_context(self, query: str) -> str:
        """
        Return a short context snippet most relevant to the query.
        Simple keyword overlap — swap with embeddings for better recall.
        """
        query_words = set(query.lower().split())
        best: list[tuple[int, str]] = []

        for source, text in {**self._kb["pages"],
                             **self._kb["channels"]}.items():
            if not isinstance(text, str):
                continue
            overlap = len(query_words & set(text.lower().split()))
            if overlap > 0:
                best.append((overlap, text[:800]))

        # Also check if a staff-corrected answer exists
        for question, correction in self._kb["corrections"].items():
            if any(w in question.lower() for w in query_words):
                best.append((999, f"[CORRECTION] Q: {question}\nA: {correction}"))

        best.sort(key=lambda x: x[0], reverse=True)
        snippets = [text for _, text in best[:3]]
        return "\n\n".join(snippets)

    # ── Scraped content ────────────────────────────────────────────────────────

    def _refresh_docs(self):
        self._docs = (
            list(self._kb["pages"].values()) +
            list(self._kb["channels"].values()) +
            list(self._kb["corrections"].values())
        )

    def upsert_page(self, url: str, text: str):
        self._kb["pages"][url] = text
        _save(Config.KNOWLEDGE_FILE, self._kb)
        self._refresh_docs()
        log.debug(f"KB updated for page: {url}")

    def upsert_channel(self, channel_id: str, summary: str):
        self._kb["channels"][channel_id] = summary
        _save(Config.KNOWLEDGE_FILE, self._kb)
        self._refresh_docs()
        log.debug(f"KB updated for channel: {channel_id}")

    # ── User corrections / self-learning ──────────────────────────────────────

    def record_correction(self, question: str, wrong_answer: str,
                           raw_feedback: str):
        """
        Store a user-flagged correction. A staff member or future process
        can promote these to confirmed corrections.
        """
        entry = {
            "question":     question,
            "wrong_answer": wrong_answer,
            "raw_feedback": raw_feedback,
            "timestamp":    datetime.utcnow().isoformat(),
            "status":       "pending",   # pending | confirmed | rejected
        }
        self._feedback.setdefault("pending", []).append(entry)
        _save(Config.FEEDBACK_FILE, self._feedback)
        log.info(f"Correction recorded for: {question!r}")

    def confirm_correction(self, question: str, correct_answer: str):
        """
        Staff or admin calls this to promote a pending correction into
        the live knowledge base so the AI uses it immediately.
        """
        self._kb["corrections"][question.lower().strip()] = correct_answer
        _save(Config.KNOWLEDGE_FILE, self._kb)
        log.info(f"Correction confirmed for: {question!r}")

    def get_pending_corrections(self) -> list:
        return self._feedback.get("pending", [])

    # ── Hot reload ─────────────────────────────────────────────────────────────

    def reload(self):
        """
        Hot-reload the knowledge base and feedback files from disk.
        Called by `!bot reload-kb` via StaffHandler so staff don't need
        to restart the bot after manually editing knowledge_base.json.
        """
        self._kb       = _load(Config.KNOWLEDGE_FILE)
        self._feedback = _load(Config.FEEDBACK_FILE)
        self._kb.setdefault("pages",       {})
        self._kb.setdefault("channels",    {})
        self._kb.setdefault("corrections", {})
        # Expose a doc count for the status command
        self._docs = (
            list(self._kb["pages"].values()) +
            list(self._kb["channels"].values()) +
            list(self._kb["corrections"].values())
        )
        log.info(f"Knowledge base reloaded: {len(self._docs)} entries")
