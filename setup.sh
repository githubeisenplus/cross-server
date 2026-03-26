#!/bin/bash
# Cross-Server Copilot Coordination — Setup Script
# Usage: bash setup.sh <helsinki|iran>

set -e

ROLE="${1:-}"
DIR="/root/.copilot/cross-server"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$ROLE" ] || { [ "$ROLE" != "helsinki" ] && [ "$ROLE" != "iran" ]; }; then
    echo "Usage: $0 <helsinki|iran>"
    exit 1
fi

echo "=== Cross-Server Setup ($ROLE) ==="

# 1. Create directory structure
echo "[1/6] Creating directories..."
mkdir -p "$DIR/tasks/pending" "$DIR/tasks/running" "$DIR/tasks/done"

# 2. Copy scripts
echo "[2/6] Installing scripts..."
cp "$REPO_DIR/scripts/worker.sh" "$DIR/worker.sh"
cp "$REPO_DIR/scripts/sync.sh" "$DIR/sync.sh"
cp "$REPO_DIR/scripts/update-state.sh" "$DIR/update-state.sh"
cp "$REPO_DIR/docs/shared-agents.md" "$DIR/shared-agents.md"
chmod +x "$DIR/worker.sh" "$DIR/sync.sh" "$DIR/update-state.sh"

# 3. Set server role
echo "[3/6] Setting role: $ROLE"
echo "$ROLE" > "$DIR/server-role"

# 4. Install systemd service
echo "[4/6] Installing systemd service..."
cp "$REPO_DIR/systemd/cross-server-worker.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable cross-server-worker
systemctl restart cross-server-worker
echo "  Worker service: $(systemctl is-active cross-server-worker)"

# 5. Setup cron sync
echo "[5/6] Setting up cron sync..."
CRON_LINE="* * * * * /bin/bash $DIR/sync.sh >> $DIR/sync.log 2>&1"
# Remove old entries
crontab -l 2>/dev/null | grep -v "cross-server/sync.sh" | crontab - 2>/dev/null || true
# Add new entry
(crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
echo "  Cron: sync every 1 minute"

# 6. Generate initial state
echo "[6/6] Generating initial state..."
bash "$DIR/update-state.sh"

echo ""
echo "=== Setup Complete ==="
echo "  Role: $ROLE"
echo "  Dir:  $DIR"
echo "  Worker: $(systemctl is-active cross-server-worker)"
echo "  Logs: $DIR/worker.log + $DIR/sync.log"
echo ""
echo "Test: cat > $DIR/tasks/pending/test-ping.json << 'EOF'"
echo '{"id":"test-ping","action":"ping","target":"'"$ROLE"'"}'
echo "EOF"
echo "Then: sleep 35 && cat $DIR/tasks/done/test-ping.json"
