# OpsLab — Social Launch Agent (MVP)

Flask + Tailwind (dark theme) app that builds an Instagram brand kit, generates a
content plan, and can optionally store login credentials to automate account
setup via a headless browser (Playwright).

## Setup

```bash
cd bot-intsa
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
playwright install chromium   # only needed for live automation

cp .env.example .env
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# paste the output into ENCRYPTION_KEY in .env
# paste an Anthropic API key into ANTHROPIC_API_KEY to enable AI generation
```

Run it:

```bash
python run.py
```

Visit http://localhost:5000.

## What's here (Phase 1–3 of the plan)

- **Onboarding** — a short conversational Q&A that builds a brand profile.
- **Brand kit** — AI-generated username ideas, bio, voice, colors, content
  pillars, CTA. Refinable with free-text instructions ("make it more premium").
- **Content studio** — generates a 30-post plan (educational/personal/
  promotional/engagement/reels) with a Draft → AI Review → Approved → Ready →
  Published status pipeline.
- **AI Agent chat** — a conversational assistant for planning changes (advisory
  only in this MVP; it doesn't take actions on its own).
- **Accounts** — stores platform credentials (Instagram/Facebook/WhatsApp/
  Discord) encrypted at rest, with an optional TOTP 2FA secret so the agent can
  generate 2FA codes itself.

## Security notes — please actually read these

You chose the "full auto-login including 2FA secrets" option, so this is what
was built. A few things worth knowing:

- **Encryption**: credentials are encrypted with Fernet (`ENCRYPTION_KEY` in
  `.env`, never commit this file). If that key or the SQLite database leaks,
  every connected account is compromised — the encryption only protects
  against someone getting the DB file alone, not both.
- **Dry-run by default**: `PUBLISH_DRY_RUN=true` means "Test login" and any
  publish action just record intent, they don't touch a real browser. Flip it
  to `false` only when you're ready for the agent to actually log in live.
- **ToS risk**: automating login/posting on Instagram, Facebook, or WhatsApp
  outside their official APIs is against most of these platforms' terms of
  service and can get an account challenged or banned, independent of code
  quality. Discord has an official bot API and is the lowest-risk platform to
  automate for real.
- **Selectors will break**: `app/services/instagram_agent.py` uses best-effort
  CSS selectors against Instagram's login page. Instagram changes this
  frequently and actively detects automated browsers — expect to maintain this
  over time, and expect occasional manual-challenge prompts that the agent
  can't get past on its own.
- This is a single-user local tool (no auth on the Flask app itself). Don't
  deploy it publicly reachable without adding authentication in front of it —
  anyone who can reach it can read/replace the stored credentials.

## Extending to Facebook / WhatsApp / Discord

- `SocialAccount.platform` already supports these values and the credential
  vault works for any of them today.
- Discord: use the official bot API (`discord.py` or raw REST) with a bot
  token instead of a password — no browser automation needed, no ToS risk.
- Facebook/WhatsApp: prefer the official Graph API / WhatsApp Business API
  where your use case qualifies, before reaching for browser automation.
