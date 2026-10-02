from flask import Blueprint, jsonify, render_template, request, session

from ..models import Brand
from ..services.ai import chat_agent

bp = Blueprint("agent", __name__, url_prefix="/agent")


@bp.route("/")
def index():
    return render_template("agent.html")


@bp.route("/message", methods=["POST"])
def message():
    data = request.get_json(force=True)
    user_message = data.get("message", "")
    history = session.get("agent_history", [])

    brand = Brand.query.order_by(Brand.id.desc()).first()
    reply = chat_agent(brand, user_message, history)

    history.append({"role": "user", "content": user_message})
    history.append({"role": "assistant", "content": reply})
    session["agent_history"] = history[-20:]

    return jsonify({"reply": reply})
