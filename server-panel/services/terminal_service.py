"""Backs the Live VPS Console: real interactive shell sessions (bash under
a PTY), multiplexed over Socket.IO. Each session is a real subprocess with
its own pseudo-terminal — input/output are byte-exact, so full-screen
programs (top, vim, less) work normally, not just simple command/response.

This intentionally does NOT use pty.fork() (which forks the whole
multi-threaded Python process — a well-known footgun: other threads' locks,
DB connections, and socketio internals can end up in a broken, half-copied
state in the child). Instead: pty.openpty() for the master/slave fd pair,
then subprocess.Popen() to fork+exec the shell — Popen handles the
fork/exec/fd-cleanup dance safely regardless of how many threads are
already running in this process.
"""
import fcntl
import os
import pty
import struct
import subprocess
import termios
import threading
import time
import uuid

MAX_SESSIONS_PER_USER = 4
IDLE_TIMEOUT_SECONDS = 20 * 60  # auto-close a session after 20 min of no input
READ_CHUNK = 4096

_sessions = {}  # session_id -> dict
_lock = threading.Lock()


class TerminalError(Exception):
    pass


def _sessions_for_user(user_id):
    return [s for s in _sessions.values() if s["user_id"] == user_id]


def open_session(user_id, on_output, cwd="/root"):
    """Starts a new shell under a PTY. on_output(session_id, text) is called
    (from a background thread) whenever the shell produces output. Returns
    the new session_id."""
    with _lock:
        if len(_sessions_for_user(user_id)) >= MAX_SESSIONS_PER_USER:
            raise TerminalError(f"Maximum of {MAX_SESSIONS_PER_USER} concurrent terminal sessions reached.")

    master_fd, slave_fd = pty.openpty()
    env = dict(os.environ, TERM="xterm-256color")
    try:
        proc = subprocess.Popen(
            ["/bin/bash", "--login"],
            stdin=slave_fd, stdout=slave_fd, stderr=slave_fd,
            preexec_fn=os.setsid,  # give the shell its own session/controlling tty
            env=env, cwd=cwd if os.path.isdir(cwd) else "/root",
            close_fds=True,
        )
    except OSError as exc:
        os.close(master_fd)
        os.close(slave_fd)
        raise TerminalError(f"Failed to start shell: {exc}") from exc
    finally:
        os.close(slave_fd)  # the child has its own copy; the parent doesn't need this end

    session_id = uuid.uuid4().hex
    stop_event = threading.Event()

    def _reader():
        while not stop_event.is_set():
            try:
                chunk = os.read(master_fd, READ_CHUNK)
            except OSError:
                break
            if not chunk:
                break
            with _lock:
                sess = _sessions.get(session_id)
                if sess:
                    sess["last_activity"] = time.time()
            on_output(session_id, chunk.decode("utf-8", errors="replace"))
        with _lock:
            sess = _sessions.pop(session_id, None)
        if sess:
            on_output(session_id, "\r\n\x1b[90m[session closed]\x1b[0m\r\n")

    thread = threading.Thread(target=_reader, daemon=True)
    with _lock:
        _sessions[session_id] = {
            "user_id": user_id,
            "master_fd": master_fd,
            "proc": proc,
            "stop_event": stop_event,
            "thread": thread,
            "created_at": time.time(),
            "last_activity": time.time(),
        }
    thread.start()
    return session_id


def write_input(session_id, user_id, data):
    with _lock:
        sess = _sessions.get(session_id)
    if not sess or sess["user_id"] != user_id:
        raise TerminalError("No such session.")
    sess["last_activity"] = time.time()
    try:
        os.write(sess["master_fd"], data.encode("utf-8", errors="replace"))
    except OSError as exc:
        raise TerminalError(f"Failed to write to session: {exc}") from exc


def resize(session_id, user_id, rows, cols):
    with _lock:
        sess = _sessions.get(session_id)
    if not sess or sess["user_id"] != user_id:
        return
    try:
        winsize = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(sess["master_fd"], termios.TIOCSWINSZ, winsize)
    except OSError:
        pass


def close_session(session_id, user_id):
    with _lock:
        sess = _sessions.get(session_id)
        if not sess or sess["user_id"] != user_id:
            return False
        sess["stop_event"].set()
    try:
        sess["proc"].terminate()
        sess["proc"].wait(timeout=3)
    except Exception:
        try:
            sess["proc"].kill()
        except Exception:
            pass
    try:
        os.close(sess["master_fd"])
    except OSError:
        pass
    with _lock:
        _sessions.pop(session_id, None)
    return True


def close_all_for_user(user_id):
    for session_id in [sid for sid, s in _sessions.items() if s["user_id"] == user_id]:
        close_session(session_id, user_id)


def sweep_idle_sessions():
    """Call periodically from a background loop: closes any session that's
    been idle past IDLE_TIMEOUT_SECONDS, regardless of owner."""
    now = time.time()
    stale = [
        (sid, s["user_id"]) for sid, s in list(_sessions.items())
        if now - s["last_activity"] > IDLE_TIMEOUT_SECONDS
    ]
    for sid, uid in stale:
        close_session(sid, uid)
    return len(stale)


def session_count_for_user(user_id):
    with _lock:
        return len(_sessions_for_user(user_id))
