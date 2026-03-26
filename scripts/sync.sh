#!/bin/bash
# Cross-Server Copilot Sync v1.1
# Helsinki ↔ Iran bidirectional state sync via SSH reverse tunnel

DIR="/root/.copilot/cross-server"
LOG="$DIR/sync.log"
SSH_BASE="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
MAX_LOG=500

log() { echo "$(date '+%H:%M:%S') $1" >> "$LOG"; }

[ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt "$MAX_LOG" ] && tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

find_port() {
    for p in 2222 2223 2224; do
        ss -tlnp 2>/dev/null | grep -q ":$p " && echo "$p" && return 0
    done
    return 1
}

PORT=$(find_port)
[ -z "$PORT" ] && { log "SKIP no-tunnel"; exit 0; }

# Use -tt for action commands (need PTY for ForceCommand workaround)
ssh_run() { timeout 10 ssh -tt $SSH_BASE -p "$PORT" root@localhost "$1" 2>/dev/null | tr -d '\r'; }

# 1. Update local state
bash "$DIR/update-state.sh" >/dev/null 2>&1

# 2. Push Helsinki state to Iran
B64=$(base64 -w0 "$DIR/state.json")
PUSHOUT=$(ssh_run "echo $B64 | base64 -d > /root/.copilot/cross-server/remote-state.json && echo PUSHOK")
echo "$PUSHOUT" | grep -q PUSHOK && log "PUSH OK:$PORT" || log "PUSH FAIL:$PORT"

# 3. Pull Iran state
IRAN_B64=$(ssh_run 'base64 -w0 /root/.copilot/cross-server/state.json' | grep -v '^$' | grep -v 'Connection to' | tr -d '\n\r ')
# Clean: remove any non-base64 chars, keep only valid base64
IRAN_B64=$(echo "$IRAN_B64" | tr -cd 'A-Za-z0-9+/=')
if [ ${#IRAN_B64} -gt 20 ]; then
    echo "$IRAN_B64" | base64 -d > "$DIR/remote-state.json" 2>/dev/null && log "PULL OK:$PORT (${#IRAN_B64}c)" || log "PULL DECODE-FAIL:$PORT"
else
    log "PULL FAIL:$PORT (${#IRAN_B64}c)"
fi

# 4. Clock drift
H_SEC=$(date -u +%s)
I_SEC=$(ssh_run 'date -u +%s' | tr -cd '0-9' | tail -c 11)
DRIFT=0
if [ -n "$I_SEC" ] && [ "$I_SEC" -gt 1000000000 ] 2>/dev/null; then
    DRIFT=$((H_SEC - I_SEC))
    [ $DRIFT -lt 0 ] && DRIFT=$((-DRIFT))
    [ $DRIFT -gt 5 ] && log "WARN drift=${DRIFT}s"
fi

# 5. Update last_sync + drift
python3 << PYEOF
import json
try:
    with open("$DIR/state.json") as f: s = json.load(f)
    s["last_sync"] = "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    s["clock_drift_seconds"] = $DRIFT
    with open("$DIR/state.json", "w") as f: json.dump(s, f, indent=2)
except: pass
PYEOF

# 6. Task sync (Helsinki→Iran pending, Iran→Helsinki done)
for f in "$DIR/tasks/pending/"*.json; do
    [ -f "$f" ] || continue
    TO=$(python3 -c "import json; print(json.load(open('$f')).get('to', t.get('target','')))" 2>/dev/null)
    [ "$TO" != "iran" ] && continue
    TB64=$(base64 -w0 "$f")
    FNAME=$(basename "$f")
    ssh_run "echo $TB64 | base64 -d > /root/.copilot/cross-server/tasks/pending/$FNAME && echo TOK" | grep -q TOK && log "TASK→iran $FNAME"
done

log "SYNC done:$PORT drift=${DRIFT}s"
