# Cape Flats Roleplay — Discord AI Bot

A self-learning Discord bot powered by **Ollama** that knows everything about
the CFRP FiveM server, handles applications, reports, and live player counts.

---

## Project Structure

```
cfrp_bot/
├── bot.py                    # Entry point
├── config.py                 # All settings in one place
├── requirements.txt
├── .env.example              # Copy to .env and fill in tokens
│
├── handlers/
│   ├── message_handler.py    # Central routing logic
│   ├── intent_handler.py     # Keyword shortcuts (apply, report, city count)
│   └── staff_handler.py      # Staff override commands
│
├── sessions/
│   └── session_manager.py    # Per-user conversation tracking & 30s timeout
│
├── ai/
│   └── ollama_client.py      # Ollama REST API wrapper
│
├── knowledge/
│   ├── knowledge_base.py     # Persistent KB + self-learning corrections
│   └── scraper.py            # Auto-scrapes CFRP website & Discord channels
│
└── data/                     # Auto-created at runtime (gitignored)
    ├── knowledge_base.json
    ├── feedback_corrections.json
    └── staff_overrides.json
```

---

## Setup

### 1. Prerequisites
- Python 3.11+
- [Ollama](https://ollama.ai/) installed and running locally
- A Discord bot token with **Message Content Intent** enabled

### 2. Install dependencies
```bash
cd cfrp_bot
pip install -r requirements.txt
```

### 3. Configure environment
```bash
cp .env.example .env
# Edit .env and add your DISCORD_TOKEN
```

### 4. Pull an Ollama model
```bash
ollama pull llama3
# or: ollama pull mistral
```

### 5. Run the bot
```bash
python bot.py
```

---

## Staff Commands

Staff members (role ID `1460361220329574521`) can use these commands:

| Command | Effect |
|---|---|
| `!bot silence user @mention` | Bot stops responding to that user |
| `!bot unsilence user @mention` | Restores responses for that user |
| `!bot silence channel` | Bot goes silent in the current channel |
| `!bot unsilence channel` | Bot resumes in the current channel |
| `!bot status` | Shows current silence stats |

---

## How Self-Learning Works

1. User says something like **"That's wrong"** or **"Incorrect"**
2. Bot saves the correction as **pending** in `data/feedback_corrections.json`
3. A staff member (or automated process) reviews pending corrections
4. Call `KnowledgeBase().confirm_correction(question, correct_answer)` to
   promote a correction into the live knowledge base
5. From that point on the bot will always prefer the corrected answer

---

## Customisation

- **Change the AI model** — update `OLLAMA_MODEL` in `.env`
- **Change timeout** — update `CONVERSATION_TIMEOUT` in `config.py`
- **Add more pages to scrape** — add URLs to `PAGES_TO_SCRAPE` in `knowledge/scraper.py`
- **Tweak the system prompt** — edit `SYSTEM_PROMPT` in `ai/ollama_client.py`
