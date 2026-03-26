#!/bin/bash
# Cross-Server Worker v1.0
# Background task executor for copilot coordination
# Watches tasks/pending/ and executes them automatically

DIR="/root/.copilot/cross-server"
TASKS_DIR="$DIR/tasks"
LOG="$DIR/worker.log"
ROLE=$(cat "$DIR/server-role" 2>/dev/null || echo "unknown")
POLL_INTERVAL=30
MAX_LOG=1000

# Copilot wrapper (Iran uses cop, Helsinki uses copilot directly)
if [ "$ROLE" = "iran" ]; then
    COPILOT_CMD="/usr/local/bin/cop"
else
    COPILOT_CMD="/usr/bin/copilot"
fi

# Security whitelist — commands allowed for simple execution
SIMPLE_WHITELIST=(
    "systemctl status"
    "systemctl is-active"
    "systemctl restart slipstream-client"
    "systemctl restart dns-doh-proxy"
    "systemctl restart nooshdaroo-client"
    "systemctl restart daroolink-vpn-tunnel-2"
    "systemctl restart daroolink-vpn-tunnel-3"
    "journalctl"
    "ss -tlnp"
    "dig"
    "curl --proxy"
    "cat /root/.copilot/cross-server/"
    "bash /root/.copilot/cross-server/update-state.sh"
    "bash /root/.copilot/cross-server/sync.sh"
    "date"
    "uptime"
    "df -h"
    "free -m"
    "ip addr"
    "ping -c"
    "echo"
    "hostname"
    "whoami"
    "uname"
    "cat /etc/os-release"
)

# BLOCKED commands — never execute these
BLOCKED_PATTERNS=(
    "systemctl stop xray-vpn"
    "systemctl restart xray-vpn"
    "systemctl stop daroolink-vpn-tunnel "
    "rm -rf"
    "mkfs"
    "dd if="
    "iptables"
    "ufw"
    "shutdown"
    "reboot"
    "passwd"
    "chmod 777"
)

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"; }

rotate_log() {
    [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null)" -gt "$MAX_LOG" ] && \
        tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

is_blocked() {
    local cmd="$1"
    for pattern in "${BLOCKED_PATTERNS[@]}"; do
        if [[ "$cmd" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

is_whitelisted() {
    local cmd="$1"
    for pattern in "${SIMPLE_WHITELIST[@]}"; do
        if [[ "$cmd" == "$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

execute_task() {
    local task_file="$1"
    local fname=$(basename "$task_file")
    local task_id action level command timeout_sec to_server

    # Parse task JSON (supports both flat and nested payload format)
    eval "$(python3 << PYEOF
import json, sys
try:
    t = json.load(open("$task_file"))
    print(f'task_id="{t.get("id","unknown")}"')
    # action: try "action", fallback to "type"
    action = t.get("action", t.get("type", ""))
    print(f'action="{action}"')
    print(f'level="{t.get("level","simple")}"')
    # command: try payload.command, fallback to top-level "command"
    p = t.get("payload", {})
    cmd = p.get("command", "") if p else ""
    if not cmd:
        cmd = t.get("command", "")
    print(f'command={repr(cmd)}')
    prompt = p.get("prompt", "") if p else ""
    if not prompt:
        prompt = t.get("prompt", "")
    print(f'prompt={repr(prompt)}')
    timeout = p.get("timeout", 30) if p else 30
    if not timeout:
        timeout = t.get("timeout", 30)
    print(f'timeout_sec="{timeout}"')
    # to_server: try "to", fallback to "target"
    to = t.get("to", t.get("target", ""))
    print(f'to_server="{to}"')
except Exception as e:
    print(f'task_id="error"', file=sys.stderr)
    sys.exit(1)
PYEOF
    )"

    # Only process tasks addressed to this server
    if [ "$to_server" != "$ROLE" ]; then
        return 0
    fi

    log "TASK START: $task_id (action=$action, level=$level)"

    # Move to running
    mv "$task_file" "$TASKS_DIR/running/$fname"
    local running_file="$TASKS_DIR/running/$fname"

    local result_status="done"
    local result_output=""
    local result_success="true"

    case "$action" in
        run_command|simple|exec)
            if is_blocked "$command"; then
                result_output="BLOCKED: command matches security blocklist"
                result_success="false"
                result_status="failed"
                log "BLOCKED: $command"
            elif is_whitelisted "$command"; then
                result_output=$(timeout "${timeout_sec}" bash -c "$command" 2>&1 | tail -50)
                [ $? -ne 0 ] && result_success="false" && result_status="failed"
                log "EXEC simple: $command → $result_status"
            else
                result_output="NOT WHITELISTED: command requires manual approval"
                result_success="false"
                result_status="pending_approval"
                log "NOT WHITELISTED: $command"
            fi
            ;;

        check_status)
            bash "$DIR/update-state.sh" >/dev/null 2>&1
            result_output=$(cat "$DIR/state.json")
            log "STATUS: updated"
            ;;

        smart)
            if [ -z "$prompt" ]; then
                result_output="ERROR: no prompt provided"
                result_success="false"
                result_status="failed"
            else
                log "SMART: invoking copilot -p"
                result_output=$(timeout 120 "$COPILOT_CMD" -p "$prompt" --allow-all-tools --autopilot 2>&1 | tail -100)
                local exit_code=$?
                [ $exit_code -ne 0 ] && result_success="false" && result_status="failed"
                log "SMART: copilot finished (exit=$exit_code)"
            fi
            ;;

        ping)
            result_output="pong from $ROLE at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            log "PING: responded"
            ;;

        message|info|notify)
            result_output="ACK: message received by $ROLE worker"
            log "MSG: received info/message task"
            ;;

        *)
            result_output="UNKNOWN action: $action"
            result_success="false"
            result_status="failed"
            log "UNKNOWN: $action"
            ;;
    esac

    # Write result to done/ (use temp file to avoid quoting issues)
    echo "$result_output" > /tmp/worker-result.txt
    python3 << PYEOF
import json
try:
    t = json.load(open("$running_file"))
    t["status"] = "$result_status"
    output = open("/tmp/worker-result.txt").read().strip()[:2000]
    t["result"] = {"success": "$result_success" == "true", "output": output}
    t["completed_at"] = "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    t["executed_by"] = "$ROLE"
    with open("$TASKS_DIR/done/$fname", "w") as f:
        json.dump(t, f, indent=2)
except Exception as e:
    print(f"ERROR writing result: {e}")
PYEOF

    # Remove from running
    rm -f "$running_file"
    log "TASK DONE: $task_id → $result_status"
}

# === Main Loop ===
log "WORKER START ($ROLE)"

while true; do
    rotate_log

    # Process all pending tasks
    for task_file in "$TASKS_DIR/pending/"*.json; do
        [ -f "$task_file" ] || continue
        execute_task "$task_file"
    done

    sleep "$POLL_INTERVAL"
done
