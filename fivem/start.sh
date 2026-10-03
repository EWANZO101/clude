#!/bin/bash
# Start FXServer through txAdmin (web panel on port 40120)
cd /root/fivem
export TXHOST_DATA_PATH=/root/fivem/txData
export TXHOST_TXA_PORT=40120
exec /root/fivem/server/run.sh "$@"
