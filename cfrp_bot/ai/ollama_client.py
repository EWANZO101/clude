"""
OllamaClient — wraps the Ollama REST API for chat completions.
"""

import asyncio  # ← must be at the top (was incorrectly at the bottom — bug fix)
import aiohttp
import logging
from config import Config

log = logging.getLogger("cfrp_bot.ollama")

# Kept short deliberately — shorter prompt = faster first token
SYSTEM_PROMPT = (
    "You are GSRP AI, the assistant for goldenshoresrp (FiveM). "
    "Be helpful, concise, and friendly. "
    "Only answer questions about GSRP. "
    "If unsure, say so honestly. "
    "Website: https://web.goldenshoresrp.com"
)


class OllamaClient:
    def __init__(self):
        self.base_url = Config.OLLAMA_BASE_URL
        self.model    = Config.OLLAMA_MODEL
        # Reuse a single aiohttp session for the bot's lifetime (faster)
        self._session: aiohttp.ClientSession | None = None

    def _get_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession()
        return self._session

    async def chat(self, user_message: str, context: str = "",
                   history: list | None = None) -> str:
        system = SYSTEM_PROMPT
        if context:
            # Trim context to avoid ballooning the prompt
            system += f"\n\nContext:\n{context[:600]}"

        messages = [{"role": "system", "content": system}]
        if history:
            # Only send last 6 messages (3 exchanges) to reduce token load
            messages.extend(history[-6:])
        messages.append({"role": "user", "content": user_message})

        payload = {
            "model":    self.model,
            "messages": messages,
            "stream":   False,
            "options": {
                "num_predict": 300,   # cap reply length → faster response
                "temperature": 0.7,
                "num_ctx":     2048,  # smaller context window → faster
            },
        }

        try:
            session = self._get_session()
            async with session.post(
                f"{self.base_url}/api/chat",
                json=payload,
                timeout=aiohttp.ClientTimeout(total=120),  # was 30 — too short
            ) as resp:
                if resp.status != 200:
                    err = await resp.text()
                    log.error(f"Ollama error {resp.status}: {err}")
                    return "⚠️ I'm having trouble thinking right now. Try again in a moment."
                data = await resp.json()
                return data["message"]["content"].strip()

        except asyncio.TimeoutError:
            log.warning("Ollama request timed out")
            return "⚠️ The AI took too long to respond. Please try again."
        except aiohttp.ClientConnectorError:
            log.error("Cannot connect to Ollama — is it running?")
            return "⚠️ Cannot reach the AI service. Please contact an admin."
        except Exception as e:
            log.error(f"Ollama request failed: {e}")
            return "⚠️ Something went wrong on my end. Please try again shortly."

    async def close(self):
        """Call on bot shutdown to cleanly close the HTTP session."""
        if self._session and not self._session.closed:
            await self._session.close()
