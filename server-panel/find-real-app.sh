#!/usr/bin/env bash
# Locates the actual running panel process + its working directory + port,
# since the real deploy path differs from /opt/opslab-panel on this host.
echo "== Running app.py process(es) =="
ps aux | grep "[a]pp.py"

echo
echo "== Working directory of that process =="
PID=$(pgrep -f "app.py" | head -1)
if [ -n "$PID" ]; then
  echo "PID: $PID"
  echo -n "CWD: "
  readlink -f "/proc/$PID/cwd"
  echo
  echo "== Listening ports for that PID =="
  ss -ltnp 2>/dev/null | grep "pid=$PID" || netstat -ltnp 2>/dev/null | grep "$PID/"
else
  echo "No app.py process found."
fi

echo
echo "== Confirm tailwind.css exists there =="
REAL_DIR=$(readlink -f "/proc/$PID/cwd" 2>/dev/null)
if [ -n "$REAL_DIR" ]; then
  ls -la "$REAL_DIR/static/css/tailwind.css" 2>/dev/null || echo "Not found at $REAL_DIR/static/css/tailwind.css"
fi
