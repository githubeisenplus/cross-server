# Cross-Server Copilot Coordination Protocol v2.0
# مستندات هماهنگی کوپایلوت بین دو سرور
# بروزرسانی: 2026-03-26

## Architecture
- **Helsinki** (46.62.144.63, aarch64): Hub — DNS tunnel server, smart-gateway, Rust build
- **Iran** (192.168.0.105, x86_64): Spoke — pharmacy system, VPN client, DNS tunnel client

## Components

### 1. Worker Daemon (`cross-server-worker.service`)
Background task executor on BOTH servers. Polls `tasks/pending/` every 30s.

| Action | Level | Description |
|--------|-------|-------------|
| `simple` / `run_command` / `exec` | bash | Whitelisted commands only |
| `smart` | copilot -p | AI-powered (30 premium req, ~53s) |
| `ping` | instant | Health check → pong |
| `check_status` | bash | Run update-state.sh, return state.json |
| `message` / `info` / `notify` | instant | ACK receipt |

**Security**: Whitelist (echo, systemctl status, dig, curl, journalctl, etc.) + Blocklist (xray-vpn stop/restart, rm -rf, iptables, reboot, etc.)

### 2. Sync (`sync.sh` via cron)
| Direction | Method | Interval | Port |
|-----------|--------|----------|------|
| Iran→Helsinki | `proxychains4 ssh :443` via VPN SOCKS5 | 2 min | 443 |
| Helsinki→Iran | `ssh -p 2222/2223/2224 localhost` via reverse tunnel | 1 min | 2222-2224 |

Single SSH session per sync (push state + pull state + clock drift + deliver tasks).

### 3. State Files
| File | Location | Purpose |
|------|----------|---------|
| `state.json` | Both servers | Local server status (services, tunnels, ports) |
| `remote-state.json` | Both servers | Copy of OTHER server's state |
| `server-role` | Both | "iran" or "helsinki" |
| `worker.log` | Both | Worker execution log (rotated at 1000 lines) |
| `sync.log` | Both | Sync log (rotated at 500 lines) |

### 4. Task Queue (file-based)
```
tasks/pending/   — waiting for worker or sync delivery
tasks/running/   — currently executing (moved by worker)
tasks/done/      — completed with results (moved by worker)
```

## Task Format (v2 — supports flat and nested)
```json
{
  "id": "unique-task-id",
  "action": "simple|smart|ping|check_status|message",
  "target": "iran|helsinki",
  "command": "echo hello",
  "prompt": "Check tunnel stability (for smart tasks)",
  "timeout": 30,
  "created_by": "iran-copilot|helsinki-copilot|user",
  "status": "pending → running → done|failed|pending_approval",
  "result": {"success": true, "output": "..."},
  "completed_at": "2026-03-26T15:00:00Z",
  "executed_by": "iran|helsinki"
}
```

> Legacy format (`to`/`from`/`payload.command`) also supported.

## How Copilots Use This

### Creating a task (from either server):
```bash
cat > ~/.copilot/cross-server/tasks/pending/my-task.json << 'EOF'
{"id":"my-task","action":"simple","target":"helsinki","command":"uptime"}
EOF
# sync.sh delivers on next cron run, or: bash ~/.copilot/cross-server/sync.sh
```

### Checking results:
```bash
cat ~/.copilot/cross-server/tasks/done/my-task.json
# → {"status":"done","result":{"success":true,"output":"..."},"executed_by":"helsinki"}
```

### Manual sync:
```bash
bash ~/.copilot/cross-server/sync.sh
```

## Resilience
- Sync tolerates tunnel drops (skip and retry next cron cycle)
- Iran sync: VPN-based SSH, ~50% first-attempt success, retry usually works
- Helsinki sync: failover across 3 reverse tunnel ports (2222→2223→2224)
- Worker auto-restarts via systemd (RestartSec=10)
- State files persist on disk (survive reboots)
- Clock drift ~7-14s is normal (VPN latency artifact)

## Systemd Services
| Service | Iran | Helsinki |
|---------|------|----------|
| `cross-server-worker` | After=xray-vpn | After=network.target |
| cron sync | `*/2 * * * *` | `* * * * *` |

## Files on Each Server
```
/root/.copilot/cross-server/
├── server-role          # "iran" or "helsinki"
├── state.json           # local status
├── remote-state.json    # other server's status
├── worker.sh            # task executor daemon
├── worker.log           # worker execution log
├── sync.sh              # bidirectional sync script
├── sync.log             # sync log
├── update-state.sh      # generates state.json
├── shared-agents.md     # THIS FILE (synced to both)
└── tasks/
    ├── pending/         # waiting for execution/delivery
    ├── running/         # currently executing
    └── done/            # completed with results
```
