from app import create_app

app = create_app()

if __name__ == "__main__":
    # threaded=True matters more than usual here: get_pending_command below
    # now long-polls (holds the connection open for up to ~20s waiting for
    # a command) so Start/Stop/Restart/Run-command feel instant instead of
    # waiting for the next ~15s poll interval. Without threaded=True,
    # Werkzeug's dev server handles one request at a time — every other
    # request (heartbeats, other instances' polls, the Admin Panel's own
    # pages) would queue up behind whichever connection is mid-long-poll
    # for up to 20 seconds. This is still the Werkzeug dev server, not a
    # production WSGI server (gunicorn is in requirements.txt but nothing
    # in this deployment actually invokes it yet — every deploy so far has
    # used `nohup python run.py`) — a separate, known gap from this fix.
    #
    # use_reloader=True keeps the "edit a file, it hot-reloads" workflow
    # this whole project relies on (see OWNERSHIP.md). use_debugger=False
    # is the actual fix: debug=True previously turned BOTH on together,
    # and use_debugger=True is what serves Werkzeug's interactive
    # debugger — an unauthenticated, PIN-"protected" but historically
    # brute-forceable Python console — AND full tracebacks with local
    # variable dumps on any unhandled exception, to any visitor, on a
    # process bound to 0.0.0.0 and reachable at a public domain. Found
    # live on this exact deployment during a security pass; fixed here
    # without touching how the process is started/restarted.
    app.run(debug=False, use_reloader=True, use_debugger=False, host="0.0.0.0", port=6090, threaded=True)
