#!/bin/bash
DIR="/root/.copilot/cross-server"
STATE="$DIR/state.json"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ROLE=$(cat "$DIR/server-role" 2>/dev/null || echo "unknown")

if [ "$ROLE" = "helsinki" ]; then
    IP="46.62.144.63"
    SVCS="slipstream-server smart-gateway dns-dispatch dns-mux doh-server cloudflared dnsmasq nooshdaroo-server squid"
elif [ "$ROLE" = "iran" ]; then
    IP="192.168.0.105"
    SVCS="xray-vpn daroolink-vpn-tunnel daroolink-vpn-tunnel-2 daroolink-vpn-tunnel-3 vpn-watchdog.timer slipstream-client dns-doh-proxy nooshdaroo-client"
else
    echo "ERROR: Unknown role" >&2; exit 1
fi

# Build state with python
python3 << PYEOF
import json, subprocess

role = "$ROLE"
ip = "$IP"
now = "$NOW"
svcs = "$SVCS".split()

services = {}
for s in svcs:
    r = subprocess.run(["systemctl", "is-active", s], capture_output=True, text=True)
    services[s] = r.stdout.strip() or "unknown"

tunnels = {}
r = subprocess.run(["ss", "-tlnp"], capture_output=True, text=True)
if role == "helsinki":
    for p in [2222, 2223, 2224]:
        tunnels[str(p)] = "up" if (":" + str(p) + " ") in r.stdout else "down"
elif role == "iran":
    for p in [10808, 10809, 1080, 1083]:
        tunnels[str(p)] = "up" if (":" + str(p) + " ") in r.stdout else "down"

state = {
    "server": role,
    "ip": ip,
    "updated_at": now,
    "services": services,
    "tunnels": tunnels,
    "copilot_active": True,
    "last_sync": ""
}

# Preserve last_sync and clock_drift
try:
    with open("$DIR/state.json") as f:
        old = json.load(f)
    state["last_sync"] = old.get("last_sync", "")
    if "clock_drift_seconds" in old:
        state["clock_drift_seconds"] = old["clock_drift_seconds"]
except: pass

with open("$DIR/state.json", "w") as f:
    json.dump(state, f, indent=2)

print(f"OK: {role} state updated at {now}")
PYEOF
