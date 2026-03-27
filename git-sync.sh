#!/bin/bash
# Auto-sync cross-server scripts to GitHub
# Role-aware: Iran uses HTTP proxy, Helsinki direct

DIR="/root/.copilot/cross-server"
REPO_DIR="/tmp/cross-server-repo"
REMOTE="https://github.com/githubeisenplus/cross-server.git"
ROLE=$(cat "$DIR/server-role" 2>/dev/null || echo "unknown")

# Iran needs proxy for git operations
GIT_CMD="git"
if [ "$ROLE" = "iran" ]; then
    GIT_CMD="git -c http.proxy=http://127.0.0.1:10809"
fi

# Clone or update repo
if [ -d "$REPO_DIR/.git" ]; then
    cd "$REPO_DIR" && $GIT_CMD pull --quiet origin main 2>/dev/null || true
else
    $GIT_CMD clone "$REMOTE" "$REPO_DIR" 2>/dev/null || {
        mkdir -p "$REPO_DIR"
        cd "$REPO_DIR"
        git init && git remote add origin "$REMOTE"
    }
fi

cd "$REPO_DIR"

# Ensure proxy is set for this repo (Iran)
if [ "$ROLE" = "iran" ]; then
    git config http.proxy http://127.0.0.1:10809
fi

git config user.email "eisenplus@gmail.com"
git config user.name "DarooLink-$ROLE"

# Copy latest scripts from live system
cp "$DIR/worker.sh" scripts/worker.sh 2>/dev/null || true
cp "$DIR/update-state.sh" scripts/update-state.sh 2>/dev/null || true
cp "$DIR/shared-agents.md" docs/shared-agents.md 2>/dev/null || true
cp /etc/systemd/system/cross-server-worker.service systemd/ 2>/dev/null || true

# Server-specific sync.sh
mkdir -p "scripts/$ROLE"
cp "$DIR/sync.sh" "scripts/$ROLE/sync.sh" 2>/dev/null || true

# Commit and push if changes
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git add -A
    git commit -m "Auto-update from $ROLE at $(date -u '+%Y-%m-%dT%H:%M:%SZ')

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
    $GIT_CMD push origin main
    echo "✅ Pushed changes from $ROLE"
else
    echo "No changes to push"
fi
