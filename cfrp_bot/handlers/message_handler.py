"""
MessageHandler — routes every incoming message to the correct subsystem.
Instantiated once at bot startup, not on every message.
"""

import discord
import logging
from config import Config
from sessions.session_manager import SessionManager
from ai.ollama_client import OllamaClient
from knowledge.knowledge_base import KnowledgeBase
from handlers.intent_handler import IntentHandler
from handlers.staff_handler import StaffHandler

log = logging.getLogger("cfrp_bot.message_handler")


class MessageHandler:
    """Singleton — create once in bot.py and reuse."""

    def __init__(self, bot: discord.Client):
        self.bot            = bot
        self.session_mgr    = SessionManager()
        self.ollama         = OllamaClient()
        self.kb             = KnowledgeBase()
        self.intent_handler = IntentHandler()
        self.staff_handler  = StaffHandler(ollama=self.ollama, kb=self.kb)

    async def process(self, message: discord.Message):
        bot_mentioned = self.bot.user in message.mentions
        user_id    = message.author.id
        channel_id = message.channel.id

        # ── 1. Staff override commands ─────────────────────────────────────────
        if self.staff_handler.is_staff(message.author):
            handled = await self.staff_handler.handle(message)
            if handled:
                return

        # ── 2. Check if bot is silenced in this channel / for this user ────────
        if self.staff_handler.is_silenced(user_id, channel_id):
            return

        # ── 3. Only respond when mentioned or already in an active session ──────
        active_session = self.session_mgr.get_session(user_id, channel_id)
        if not bot_mentioned and not active_session:
            return

        # ── 4. If another user is mentioned mid-session, drop old session ───────
        if active_session and not bot_mentioned:
            other_mentions = [m for m in message.mentions if m != self.bot.user]
            if other_mentions:
                self.session_mgr.end_session(user_id, channel_id)
                return

        # ── 5. Refresh / create session ────────────────────────────────────────
        self.session_mgr.refresh_session(
            user_id, channel_id,
            timeout=Config.CONVERSATION_TIMEOUT,
            on_expire=self._on_session_expire,
        )

        content = message.content.replace(f"<@{self.bot.user.id}>", "").strip()
        if not content:
            await message.reply("Hey! How can I help? 😊", mention_author=False)
            return

        # ── 6. Feedback / correction detection ────────────────────────────────
        if self.intent_handler.is_correction(content):
            await self._handle_correction(message, content, active_session)
            return

        # ── 7. Built-in intent shortcuts (no AI needed) ───────────────────────
        intent = self.intent_handler.detect(content)
        if intent:
            await self.intent_handler.respond(message, intent)
            self.session_mgr.end_session(user_id, channel_id)
            return

        # ── 8. AI response via Ollama ──────────────────────────────────────────
        async with message.channel.typing():
            context = self.kb.build_context(content)
            history = self.session_mgr.get_history(user_id, channel_id)
            reply   = await self.ollama.chat(
                user_message=content,
                context=context,
                history=history,
            )

        self.session_mgr.append_history(user_id, channel_id,
                                        user=content, assistant=reply)
        await message.reply(reply, mention_author=False)

    async def _handle_correction(self, message: discord.Message,
                                  content: str, session):
        """User is telling the bot its last answer was wrong."""
        last_answer = self.session_mgr.get_last_answer(
            message.author.id, message.channel.id)

        if not last_answer:
            await message.reply(
                "I'm not sure what answer to correct — could you be more specific?",
                mention_author=False,
            )
            return

        self.kb.record_correction(
            question=last_answer["question"],
            wrong_answer=last_answer["answer"],
            raw_feedback=content,
        )
        await message.reply(
            "Thanks for the correction! I've noted it. "
            "What should the correct answer be?",
            mention_author=False,
        )

    @staticmethod
    def _on_session_expire(user_id: int, channel_id: int):
        log.debug(f"Session expired — user {user_id} in channel {channel_id}")
