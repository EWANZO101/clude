"""
Local Admin AI — inference engine (Part 6 rewrite).

WHY THIS CHANGED FROM PART 1: llama-cpp-python has no prebuilt wheel for
every Python version (this build is on 3.14, brand new enough that none
exists yet), so pip fell back to building it from source -- which needs
CMake *and* a working MSVC toolchain (nmake/cl.exe) on the build
machine. That's a new build-machine requirement this project never had,
which is exactly what "run within the current spec" ruled out.

Fix: drop the Python binding entirely. llama.cpp's own project publishes
a prebuilt, statically-linked llama-server.exe for Windows (CPU build,
no CUDA/Vulkan needed) -- see installer/get-llama-server.ps1, which
downloads it once into vendor/llama/. This module just launches that
exe as a subprocess and talks to its OpenAI-compatible HTTP API with
stdlib urllib -- no new pip dependency at all, so there is nothing left
for the build venv to compile.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

log = logging.getLogger("ai_engine")

_lock = threading.Lock()
_proc: subprocess.Popen | None = None
_proc_model_path: str | None = None
_proc_port: int | None = None

STARTUP_TIMEOUT_SECONDS = 60  # a CPU-only cold load of even a small model can take a while
HEALTH_TIMEOUT_SECONDS = 2
REQUEST_TIMEOUT_SECONDS = 120


class AIEngineError(Exception):
    pass


def _binary_path() -> str | None:
    """Where llama-server.exe actually is, in both the frozen exe and a
    plain source checkout. get-llama-server.ps1 always populates
    vendor/llama/llama-server.exe; build.spec bundles that folder into
    the frozen exe at the same relative path (see its datas list)."""
    if getattr(sys, "frozen", False):
        base = getattr(sys, "_MEIPASS", os.path.dirname(sys.executable))
    else:
        base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # project root, one up from app/
    candidate = os.path.join(base, "vendor", "llama", "llama-server.exe")
    return candidate if os.path.isfile(candidate) else None


def status(settings) -> dict:
    """Cheap, side-effect-free check for the AI Settings page / chat UI
    to show before anyone sends a message."""
    if not settings.enabled:
        return {"state": "disabled"}
    binary = _binary_path()
    if not binary:
        return {"state": "engine_unavailable"}  # get-llama-server.ps1 hasn't been run for this build
    if not settings.model_path:
        return {"state": "no_model"}
    if not os.path.isfile(settings.model_path):
        return {"state": "model_missing", "model_path": settings.model_path}
    with _lock:
        running = _proc is not None and _proc.poll() is None and _proc_model_path == settings.model_path
    if running and _health_check(_proc_port):
        return {"state": "ready", "model_label": settings.model_label}
    return {"state": "not_loaded", "model_label": settings.model_label}


def _health_check(port: int | None) -> bool:
    if not port:
        return False
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=HEALTH_TIMEOUT_SECONDS) as resp:
            return resp.status == 200
    except Exception:
        return False


def unload() -> None:
    """Stops the running llama-server.exe subprocess, if any. Called
    when an admin disables the AI or changes model_path/port, so a
    stale process (and the RAM/CPU it's holding) doesn't linger."""
    global _proc, _proc_model_path, _proc_port
    with _lock:
        if _proc is not None:
            log.info("Stopping local AI server (pid %s)", _proc.pid)
            try:
                _proc.terminate()
                _proc.wait(timeout=10)
            except Exception:
                try:
                    _proc.kill()
                except Exception:
                    pass
        _proc = None
        _proc_model_path = None
        _proc_port = None


def _ensure_running(settings, port: int) -> None:
    """Starts llama-server.exe if it isn't already running against the
    currently-configured model on the given port. Restarts it if the
    model path changed or the previous process died."""
    global _proc, _proc_model_path, _proc_port

    binary = _binary_path()
    if not binary:
        raise AIEngineError(
            "llama-server.exe is not bundled with this build -- run "
            "installer/get-llama-server.ps1 once before building."
        )
    if not settings.model_path or not os.path.isfile(settings.model_path):
        raise AIEngineError("No local model file is configured. Set one on the AI Settings page.")

    with _lock:
        already_good = (
            _proc is not None and _proc.poll() is None
            and _proc_model_path == settings.model_path and _proc_port == port
        )
        if already_good:
            return

        # Model/port changed, or the process died -- clear out the old one first.
        if _proc is not None:
            try:
                _proc.terminate()
                _proc.wait(timeout=10)
            except Exception:
                pass

        log.info("Starting local AI server: %s (port %d)", settings.model_path, port)
        creationflags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        _proc = subprocess.Popen(
            [
                binary,
                "-m", settings.model_path,
                "-c", str(settings.context_tokens),
                "-t", str(max(1, (os.cpu_count() or 2) - 1)),  # leave a core for the kiosk API itself
                "--host", "127.0.0.1",
                "--port", str(port),
                "--no-webui",
            ],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=creationflags,
        )
        _proc_model_path = settings.model_path
        _proc_port = port

    deadline = time.time() + STARTUP_TIMEOUT_SECONDS
    while time.time() < deadline:
        if _proc.poll() is not None:
            raise AIEngineError("llama-server.exe exited immediately -- check the model file is a valid GGUF.")
        if _health_check(port):
            return
        time.sleep(0.5)
    raise AIEngineError("Local AI server did not become ready in time.")


SYSTEM_PROMPT = (
    "You are the built-in Admin AI for StockTool Kiosk, a local inventory, "
    "tools, welding-wire, and project tracking application. You only help "
    "with using and understanding THIS application -- its pages, features, "
    "stock, tools, projects, users, permissions, syncing, backups, and "
    "settings. You do not have general internet knowledge and must not "
    "claim to. If asked something unrelated to this application, say so "
    "briefly and redirect to what you can help with. When given retrieved "
    "context below, base your answer on it rather than guessing; if the "
    "context doesn't cover the question, say you don't have that "
    "information rather than inventing details."
)


def generate(settings, conversation_messages: list[dict], context_snippets: list[str],
             llama_server_port: int = 8422) -> str:
    """conversation_messages: [{"sender": "user"|"assistant", "content": str}, ...]
    context_snippets: retrieved knowledge-base / live-config text (ai_knowledge.py).
    llama_server_port: the port the bundled llama-server.exe listens on
    for actual inference -- distinct from ai_port (the Flask AI API's own
    port); see app/settings.py."""
    _ensure_running(settings, llama_server_port)

    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    if context_snippets:
        messages.append({
            "role": "system",
            "content": "Relevant information about this installation:\n\n" + "\n\n".join(context_snippets),
        })
    for m in conversation_messages:
        role = "user" if m["sender"] == "user" else "assistant"
        messages.append({"role": role, "content": m["content"]})

    body = json.dumps({
        "messages": messages,
        "temperature": settings.temperature,
        "max_tokens": settings.max_response_tokens,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{llama_server_port}/v1/chat/completions",
        data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT_SECONDS) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        return result["choices"][0]["message"]["content"].strip()
    except (urllib.error.URLError, KeyError, ValueError, IndexError) as exc:
        log.exception("Local AI generation failed")
        raise AIEngineError(f"Local AI generation failed: {exc}") from exc
