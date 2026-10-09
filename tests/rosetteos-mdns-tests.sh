#!/bin/bash
# RosetteOS Multicast DNS (mDNS) Test Suite
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

TARGET_PYTHON_SITE="$REPO_ROOT/vendor/system/buildroot/output/target/usr/lib/python3.14/site-packages"
MDNS_DAEMON="$REPO_ROOT/scripts/build/overlay/usr/sbin/rosetteos-mdns"
MDNS_CONFIG="$REPO_ROOT/scripts/build/overlay/etc/default/rosetteos-mdns"
MDNS_INIT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S41rosetteos-mdns"
MOONRAKER_CONF="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/moonraker.conf"

FAILED=0
check() {
    local desc="$1"
    local status="$2"
    if [ "$status" -eq 0 ]; then
        echo "  PASS: $desc"
    else
        echo "  FAIL: $desc"
        FAILED=1
    fi
}

echo "=== Test 1: Moonraker [zeroconf] Configuration ==="
[ -f "$MOONRAKER_CONF" ]
check "moonraker.conf exists" $?

grep -q "^\\[zeroconf\\]" "$MOONRAKER_CONF"
check "moonraker.conf contains [zeroconf] component" $?

echo "=== Test 2: mDNS Daemon Script Permissions & Help ==="
[ -x "$MDNS_DAEMON" ]
check "rosetteos-mdns is executable" $?

PYTHONPATH="$TARGET_PYTHON_SITE" python3 "$MDNS_DAEMON" --help >/dev/null
check "rosetteos-mdns executes and displays --help" $?

echo "=== Test 3: Default Configuration File Validation ==="
[ -f "$MDNS_CONFIG" ]
check "etc/default/rosetteos-mdns exists" $?

grep -q '^ENABLED="yes"' "$MDNS_CONFIG"
check "default config enables mDNS daemon" $?

grep -q '^HOSTNAME="rosetteos"' "$MDNS_CONFIG"
check "default config sets hostname to rosetteos" $?

grep -q '^SERVICES=.*http.*ssh.*octoprint.*moonraker' "$MDNS_CONFIG"
check "default config advertises http, ssh, octoprint, moonraker" $?

echo "=== Test 4: Init Script Syntax & Lifecycle ==="
[ -x "$MDNS_INIT" ]
check "S41rosetteos-mdns is executable" $?

bash -n "$MDNS_INIT"
check "S41rosetteos-mdns shell syntax is valid" $?

echo "=== Test 5: Zeroconf Record Construction Unit Test ==="
PYTHONPATH="$TARGET_PYTHON_SITE" python3 - <<'EOF'
import socket
from zeroconf import Zeroconf, ServiceInfo

# Mock / test service info creation
zc = Zeroconf()
ip_bytes = socket.inet_aton("192.168.1.100")
hostname = "rosetteos"
domain = "local"
server_fqdn = f"{hostname}.{domain}."

# 1. HTTP service
s_http = ServiceInfo(
    type_="_http._tcp.local.",
    name=f"{hostname} Web Interface._http._tcp.local.",
    addresses=[ip_bytes],
    port=80,
    properties={"path": "/", "adminurl": f"http://{hostname}.{domain}/"},
    server=server_fqdn
)
assert s_http.port == 80
assert s_http.server == "rosetteos.local."
assert s_http.properties[b"path"] == b"/"

# 2. SSH service
s_ssh = ServiceInfo(
    type_="_ssh._tcp.local.",
    name=f"{hostname} SSH._ssh._tcp.local.",
    addresses=[ip_bytes],
    port=22,
    server=server_fqdn
)
assert s_ssh.port == 22
assert s_ssh.server == "rosetteos.local."

# 3. OctoPrint emulation
s_octo = ServiceInfo(
    type_="_octoprint._tcp.local.",
    name=f"{hostname} OctoPrint API._octoprint._tcp.local.",
    addresses=[ip_bytes],
    port=80,
    properties={"path": "/api", "version": "1.0.0"},
    server=server_fqdn
)
assert s_octo.port == 80
assert s_octo.properties[b"path"] == b"/api"

# 4. Moonraker service
s_moon = ServiceInfo(
    type_="_moonraker._tcp.local.",
    name=f"{hostname} Moonraker._moonraker._tcp.local.",
    addresses=[ip_bytes],
    port=7125,
    server=server_fqdn
)
assert s_moon.port == 7125

zc.register_service(s_http)
zc.register_service(s_ssh)
zc.register_service(s_octo)
zc.register_service(s_moon)

zc.unregister_service(s_http)
zc.unregister_service(s_ssh)
zc.unregister_service(s_octo)
zc.unregister_service(s_moon)
zc.close()
print("OK: mDNS Zeroconf registration and teardown passed")
EOF
check "python-zeroconf service registration verified" $?

echo "=== Test 6: GuppyScreen mDNS Resolution Unit Test ==="
(cd "$REPO_ROOT/../GuppyScreen" && make test-mdns >/dev/null)
check "GuppyScreen test-mdns passed" $?

echo "=========================================="
if [ "$FAILED" -eq 0 ]; then
    echo "RosetteOS mDNS Test Suite: ALL TESTS PASSED"
    exit 0
else
    echo "RosetteOS mDNS Test Suite: SOME TESTS FAILED"
    exit 1
fi
