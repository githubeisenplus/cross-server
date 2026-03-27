# 🔄 DarooLink Cross-Server Copilot Coordination

سیستم هماهنگی بین‌سروری برای مدیریت زیرساخت DarooLink.
دو سرور هلسینکی و ایران از طریق صف وظایف مبتنی بر فایل و سینک state با هم هماهنگ می‌شوند.

## 🏗️ Architecture

```
┌─────────────────┐     SSH Reverse Tunnel    ┌─────────────────┐
│  Helsinki-1     │ ◄──── 2222/2223/2224 ───► │  Iran Server    │
│  46.62.144.63   │                            │  192.168.0.105  │
│                 │  proxychains SSH:443 ►───► │                 │
│  worker.sh ✅   │                            │  worker.sh ✅   │
│  sync.sh (1min) │                            │  sync.sh (2min) │
└─────────────────┘                            └─────────────────┘
```

## 📁 Structure

```
cross-server/
├── scripts/
│   ├── worker.sh         # Background task executor (systemd service)
│   ├── sync.sh           # Bidirectional state & task sync
│   └── update-state.sh   # Local state generator
├── systemd/
│   └── cross-server-worker.service  # systemd unit file
├── docs/
│   └── shared-agents.md  # Full protocol documentation
├── tasks/
│   ├── pending/          # Tasks waiting for execution
│   ├── running/          # Currently executing
│   └── done/             # Completed with results
├── setup.sh              # One-command installer
└── git-sync.sh           # Auto-push changes to GitHub
```

## 🚀 Quick Setup

```bash
# On either server:
curl -sL https://raw.githubusercontent.com/githubeisenplus/cross-server/main/setup.sh | bash -s -- <role>
# role = "helsinki" or "iran"
```

Or manually:
```bash
git clone https://github.com/githubeisenplus/cross-server.git /root/.copilot/cross-server
cd /root/.copilot/cross-server
bash setup.sh helsinki   # or: bash setup.sh iran
```

## 📋 Task Types

| Action | Description | Example |
|--------|-------------|---------|
| `simple` | Run whitelisted bash command | `uptime`, `systemctl status xray-vpn` |
| `smart` | Invoke Copilot AI with prompt | Complex analysis, debugging |
| `ping` | Connectivity test | Returns pong + timestamp |
| `check_status` | Refresh server state | Updates state.json |
| `info` | Send informational message | Coordination notes |

## 📨 Sending a Task

```bash
cat > ~/.copilot/cross-server/tasks/pending/my-task.json << 'EOF'
{
  "id": "my-task",
  "action": "simple",
  "target": "iran",
  "command": "systemctl status xray-vpn",
  "created_by": "helsinki-copilot",
  "created_at": "2026-03-26T15:00:00Z"
}
EOF
# Sync delivers it automatically, or manually: bash scripts/sync.sh
```

## 🔒 Security

- **Whitelist**: Only safe commands allowed (status checks, logs, state updates)
- **Blocklist**: Dangerous commands permanently blocked (stop xray-vpn, rm -rf, reboot)
- **Non-whitelisted**: Returns `pending_approval` — requires manual intervention

## 🤖 Copilot Integration

In a new Copilot session, say:
> از سیستم cross-server یک task به ایران بفرست که `uptime` اجرا کنه

Copilot reads AGENTS.md → finds Cross-Server section → creates task → sync delivers.

## 📊 Monitoring

```bash
# Worker log
tail -20 ~/.copilot/cross-server/worker.log

# Sync log  
tail -20 ~/.copilot/cross-server/sync.log

# Service status
systemctl status cross-server-worker

# Remote server state
cat ~/.copilot/cross-server/remote-state.json
```

## 📄 License

Internal project — DarooLink infrastructure.

## 🔧 Server-Specific Files

Each server has its own `sync.sh` due to different connection methods:

| Server | Connection Method | sync.sh |
|--------|------------------|---------|
| Helsinki | Reverse tunnel (ports 2222-2224) | `scripts/helsinki/sync.sh` |
| Iran | SOCKS5 proxy → SSH:443 | `scripts/iran/sync.sh` |

Common scripts (`worker.sh`, `update-state.sh`) are shared.

### git-sync.sh

The `git-sync.sh` script is role-aware:
- **Helsinki**: Direct git push
- **Iran**: Uses `http.proxy=http://127.0.0.1:10809` (xray-vpn HTTP proxy)
