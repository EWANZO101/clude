"""
SessionManager — tracks active conversations, history, and per-user timers.
"""

import asyncio
import logging
from typing import Callable, Optional
from dataclasses import dataclass, field

log = logging.getLogger("cfrp_bot.sessions")


@dataclass
class Session:
    user_id: int
    channel_id: int
    history: list = field(default_factory=list)   # [{role, content}, ...]
    last_question: Optional[str] = None
    last_answer: Optional[str] = None
    _timer: Optional[asyncio.TimerHandle] = field(default=None, repr=False)


_KEY = lambda uid, cid: f"{uid}:{cid}"


class SessionManager:
    def __init__(self):
        self._sessions: dict[str, Session] = {}

    # ── Public API ─────────────────────────────────────────────────────────────

    def get_session(self, user_id: int, channel_id: int) -> Optional[Session]:
        return self._sessions.get(_KEY(user_id, channel_id))

    def refresh_session(self, user_id: int, channel_id: int,
                        timeout: int, on_expire: Callable):
        key = _KEY(user_id, channel_id)
        session = self._sessions.get(key)

        if session:
            self._cancel_timer(session)
        else:
            session = Session(user_id=user_id, channel_id=channel_id)
            self._sessions[key] = session
            log.debug(f"New session started: {key}")

        loop = asyncio.get_running_loop()  # fix: get_event_loop() is deprecated in 3.10+
        session._timer = loop.call_later(
            timeout,
            self._expire,
            user_id, channel_id, on_expire,
        )

    def end_session(self, user_id: int, channel_id: int):
        key = _KEY(user_id, channel_id)
        session = self._sessions.pop(key, None)
        if session:
            self._cancel_timer(session)
            log.debug(f"Session ended: {key}")

    def get_history(self, user_id: int, channel_id: int) -> list:
        s = self.get_session(user_id, channel_id)
        return s.history if s else []

    def append_history(self, user_id: int, channel_id: int,
                       user: str, assistant: str):
        s = self.get_session(user_id, channel_id)
        if s:
            s.history.append({"role": "user",      "content": user})
            s.history.append({"role": "assistant",  "content": assistant})
            s.last_question = user
            s.last_answer   = assistant
            # Keep history manageable (last 10 exchanges)
            if len(s.history) > 20:
                s.history = s.history[-20:]

    def get_last_answer(self, user_id: int, channel_id: int) -> Optional[dict]:
        s = self.get_session(user_id, channel_id)
        if s and s.last_question:
            return {"question": s.last_question, "answer": s.last_answer}
        return None

    # ── Internals ──────────────────────────────────────────────────────────────

    def _expire(self, user_id: int, channel_id: int, on_expire: Callable):
        key = _KEY(user_id, channel_id)
        self._sessions.pop(key, None)
        try:
            on_expire(user_id, channel_id)
        except Exception as e:
            log.error(f"Error in session expire callback: {e}")

    @staticmethod
    def _cancel_timer(session: Session):
        if session._timer:
            session._timer.cancel()
            session._timer = None
