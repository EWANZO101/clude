import json
import os

from anthropic import Anthropic

MODEL = "claude-sonnet-5"


def _client():
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        return None
    return Anthropic(api_key=api_key)


def _ask_json(system, user, fallback):
    client = _client()
    if not client:
        return fallback
    try:
        resp = client.messages.create(
            model=MODEL,
            max_tokens=2000,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        text = resp.content[0].text
        start = text.find("{")
        end = text.rfind("}")
        if start == -1:
            start = text.find("[")
            end = text.rfind("]")
        return json.loads(text[start : end + 1])
    except Exception:
        return fallback


def generate_brand_kit(profile: dict) -> dict:
    fallback = {
        "usernames": [profile.get("name", "brand").lower().replace(" ", "")],
        "display_name": profile.get("name", ""),
        "bio": f"Helping {profile.get('audience', 'people')} with {profile.get('niche', 'great content')}.",
        "colors": ["#0f172a", "#8b5cf6", "#f8fafc"],
        "fonts": ["Inter"],
        "voice": "Direct, knowledgeable, approachable",
        "content_pillars": ["Education", "Personal", "Promotional", "Engagement"],
        "highlight_categories": ["Start Here", "Results", "About"],
        "cta": "Work with me",
    }
    system = (
        "You are a branding strategist for Instagram accounts. "
        "Return ONLY a JSON object with keys: usernames (list of 5), display_name, bio, "
        "colors (list of hex codes), fonts (list), voice (short phrase), "
        "content_pillars (list of 4-6), highlight_categories (list), cta (short phrase)."
    )
    return _ask_json(system, json.dumps(profile), fallback)


def refine_brand(brand, instruction: str) -> dict:
    system = (
        "You refine an existing Instagram brand kit based on user feedback. "
        "Return ONLY a JSON object with any of these keys you are updating: "
        "bio, voice, cta, display_name, colors (list), fonts (list), content_pillars (list)."
    )
    user = json.dumps(
        {
            "current_bio": brand.bio,
            "current_voice": brand.voice,
            "instruction": instruction,
        }
    )
    return _ask_json(system, user, {})


def generate_content_plan(brand, count: int = 30) -> list:
    fallback_kinds = (
        (["educational"] * 10)
        + (["personal"] * 5)
        + (["promotional"] * 5)
        + (["engagement"] * 5)
        + (["reel"] * 5)
    )
    fallback = [
        {
            "kind": k,
            "caption": f"Draft {k} post #{i + 1} for {brand.name}.",
            "image_prompt": "",
            "script": "Hook, value, CTA." if k == "reel" else "",
        }
        for i, k in enumerate(fallback_kinds[:count])
    ]
    system = (
        "You are a social media content strategist. Given a brand profile, generate a list of "
        f"{count} Instagram posts as a JSON array: 10 educational, 5 personal, 5 promotional, "
        "5 engagement, 5 reel. Each item: {kind, caption, image_prompt, script}. "
        "script only needed for reels, otherwise empty string. Return ONLY the JSON array."
    )
    user = json.dumps(
        {
            "name": brand.name,
            "niche": brand.niche,
            "audience": brand.audience,
            "voice": brand.voice,
            "content_pillars": brand.as_list("content_pillars"),
        }
    )
    result = _ask_json(system, user, fallback)
    return result if isinstance(result, list) else fallback


def chat_agent(brand, message: str, history: list) -> str:
    client = _client()
    if not client:
        return (
            "AI agent is not configured yet. Set ANTHROPIC_API_KEY in your .env file to enable "
            "the conversational agent."
        )
    system = (
        "You are the OpsLab social media agent. You help the user plan and refine their brand and "
        "content strategy. You do not have the ability to actually publish anything yourself in this "
        "conversation - you only advise and describe what should change. Keep replies concise."
    )
    context = f"Current brand: {brand.name if brand else 'none yet'}. Niche: {brand.niche if brand else ''}."
    messages = [{"role": h["role"], "content": h["content"]} for h in history[-10:]]
    messages.append({"role": "user", "content": f"{context}\n\n{message}"})
    try:
        resp = client.messages.create(model=MODEL, max_tokens=600, system=system, messages=messages)
        return resp.content[0].text
    except Exception as e:
        return f"Something went wrong talking to the AI model: {e}"
