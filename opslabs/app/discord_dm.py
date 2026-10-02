"""Web → Discord DM notifications for tickets whose owner chose Discord replies."""
import requests
from flask import current_app, url_for


def wants_dm(ticket):
    owner = ticket.owner
    return bool(ticket.reply_via in ("discord", "both") and owner and owner.discord_id)


def bot_call(endpoint, payload, timeout=6):
    """POST to the bot's local HTTP bridge. Returns (status_code, json|None)."""
    base = current_app.config.get("DISCORD_BOT_URL")
    if not base:
        return 0, None
    try:
        r = requests.post(base.rstrip("/") + endpoint, json=payload, timeout=timeout,
                          headers={"X-Bridge-Key": current_app.config["DISCORD_BRIDGE_KEY"]})
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, None
    except requests.RequestException as e:
        current_app.logger.warning(f"Bot bridge {endpoint} unreachable: {e}")
        return 0, None


def dm_payload(ticket, *, kind, body="", author="", author_role="", from_owner=False, via="web"):
    return {
        "discord_id": ticket.owner.discord_id,
        "ticket_id": ticket.id,
        "subject": ticket.subject,
        "kind": kind,                        # opened | message | status
        "author": author,
        "author_role": author_role,
        "from_owner": from_owner,            # the customer's own message (shown as "You")
        "via": via,                          # web | channel — where the message was written
        "body": body,
        "status": ticket.status,
        "priority": ticket.priority,
        "category": ticket.category.name if ticket.category else "General",
        "company": ticket.company.name if ticket.company else "OpsLab Systems",
        "owner": ticket.owner.username,
        "resolution_note": ticket.resolution_note,
        "web_url": url_for("tickets.view", tid=ticket.id, _external=True),
    }


def notify_owner(ticket, *, kind, body="", author="", author_role="", from_owner=False, via="web"):
    """Mirror a ticket event into the owner's Discord DMs (if they chose
    Discord replies), so the DM carries the whole ticket channel. Never raises."""
    if not wants_dm(ticket):
        return False
    status, data = bot_call("/discord/dm/send", dm_payload(
        ticket, kind=kind, body=body, author=author, author_role=author_role,
        from_owner=from_owner, via=via))
    return status == 200 and bool(data and data.get("ok"))


# ---------- Staff inbox: new tickets + customer replies DM'd to staff ----------
def staff_dm_ids():
    """Discord IDs of staff who get every new ticket / customer reply in DMs."""
    import os
    raw = os.environ.get("STAFF_DM_DISCORD_IDS", "")
    return [x.strip() for x in raw.split(",") if x.strip().isdigit()]


def notify_staff(ticket, *, kind, body="", author="", via="web"):
    """kind: new | customer_message. Never raises."""
    ids = staff_dm_ids()
    if not ids:
        return False
    payload = {
        "discord_ids": ids,
        "ticket_id": ticket.id,
        "subject": ticket.subject,
        "kind": kind,
        "body": body,
        "author": author or (ticket.owner.username if ticket.owner else ""),
        "via": via,
        "status": ticket.status,
        "priority": ticket.priority,
        "category": ticket.category.name if ticket.category else "General",
        "company": ticket.company.name if ticket.company else "OpsLab Systems",
        "owner": ticket.owner.username if ticket.owner else "",
        "reply_via": ticket.reply_via or "web",
        "web_url": url_for("tickets.view", tid=ticket.id, _external=True),
    }
    status, data = bot_call("/discord/staff/notify", payload)
    return status == 200
