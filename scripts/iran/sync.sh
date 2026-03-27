#!/bin/bash
# Cross-Server Copilot Sync v1.1 — Iran Side
# All operations in ONE SSH session to minimize connection failures

DIR="/root/.copilot/cross-server"
LOG="$DIR/sync.log"
HELSINKI="46.62.144.63"
SSH_PORT="443"
SOCKS5="127.0.0.1:10808"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o ServerAliveInterval=5 -o LogLevel=ERROR"
PROXY_CMD="nc -X 5 -x $SOCKS5 %h %p"
MAX_LOG=500

log() { echo "$(date '+%H:%M:%S') $1" >> "$LOG"; }

# Rotate log
[ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt "$MAX_LOG" ] && tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# 1. Update local state
bash "$DIR/update-state.sh" >/dev/null 2>&1

# 2. Prepare local data for push
STATE_B64=$(base64 -w0 "$DIR/state.json")
TASKS_PUSH=""
for f in "$DIR/tasks/pending/"*.json; do
    [ -f "$f" ] || continue
    TO=$(python3 -c "import json; t=json.load(open('$f')); print(t.get('to', t.get('target','')))" 2>/dev/null)
    [ "$TO" != "helsinki" ] && continue
    FNAME=$(basename "$f")
    FB64=$(base64 -w0 "$f")
    TASKS_PUSH="$TASKS_PUSH echo $FB64 | base64 -d > /root/.copilot/cross-server/tasks/pending/$FNAME;"
done

# 3. Single SSH session: push state + pull state + clock + tasks
I_SEC=$(date -u +%s)
RESULT=$(timeout 25 ssh -o "ProxyCommand=$PROXY_CMD" $SSH_OPTS -p "$SSH_PORT" "root@$HELSINKI" "
# Push Iran state
echo $STATE_B64 | base64 -d > /root/.copilot/cross-server/remote-state.json && echo PUSH_OK || echo PUSH_FAIL
# Push tasks
$TASKS_PUSH
# Pull Helsinki state
echo STATE_START
base64 -w0 /root/.copilot/cross-server/state.json 2>/dev/null
echo
echo STATE_END
# Clock
echo CLOCK_\$(date -u +%s)
# Pull done tasks list
echo DONE_START
ls /root/.copilot/cross-server/tasks/done/ 2>/dev/null
echo DONE_END
" 2>/dev/null)

if [ -z "$RESULT" ]; then
    log "SSH FAIL"
    log "SYNC failed"
    exit 1
fi

# Parse results
echo "$RESULT" | grep -q "PUSH_OK" && log "PUSH OK" || log "PUSH FAIL"

# Extract Helsinki state
H_B64=$(echo "$RESULT" | sed -n '/STATE_START/,/STATE_END/p' | grep -v 'STATE_' | tr -d '[:space:]')
if [ ${#H_B64} -gt 10 ]; then
    echo "$H_B64" | base64 -d > "$DIR/remote-state.json" 2>/dev/null && log "PULL OK" || log "PULL DECODE_FAIL"
else
    log "PULL EMPTY"
fi

# Clock drift
H_SEC=$(echo "$RESULT" | grep -oP 'CLOCK_\K[0-9]+')
DRIFT=0
if [ -n "$H_SEC" ] && [ "$H_SEC" -gt 1000000000 ] 2>/dev/null; then
    DRIFT=$((I_SEC - H_SEC))
    [ $DRIFT -lt 0 ] && DRIFT=$((-DRIFT))
    [ $DRIFT -gt 5 ] && log "WARN drift=${DRIFT}s"
fi

# Mark pushed tasks as sent
for f in "$DIR/tasks/pending/"*.json; do
    [ -f "$f" ] || continue
    TO=$(python3 -c "import json; t=json.load(open('$f')); print(t.get('to', t.get('target','')))" 2>/dev/null)
    [ "$TO" = "helsinki" ] && mv "$f" "$DIR/tasks/done/$(basename $f)" && log "TASK→hel $(basename $f)"
done

# 4. Update last_sync + drift
python3 << PYEOF
import json
try:
    with open("$DIR/state.json") as f: s = json.load(f)
    s["last_sync"] = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    s["clock_drift_seconds"] = $DRIFT
    with open("$DIR/state.json", "w") as f: json.dump(s, f, indent=2)
except: pass
PYEOF

log "SYNC done drift=${DRIFT}s"
