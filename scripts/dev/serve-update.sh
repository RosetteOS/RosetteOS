#!/usr/bin/env bash
# ==============================================================================
# OpenKE Local Dev Update Server
# ==============================================================================
# Serves the latest built .swu package over local HTTP for rapid testing
# and deployment to printers on your local LAN without needing USB drives.
#
# Usage:
#   ./scripts/dev/serve-update.sh [PORT] [PRINTER_IP]
#
# Examples:
#   ./scripts/dev/serve-update.sh
#   ./scripts/dev/serve-update.sh 8080
#   ./scripts/dev/serve-update.sh 8000 192.168.1.120
# ==============================================================================

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACTS_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
SERVING_DIR="$REPO_ROOT/build-work/dev-update-server"

PORT="${1:-8000}"
PRINTER_IP="${2:-}"

mkdir -p "$SERVING_DIR"

# Find latest .swu package
LATEST_SWU=$(ls -t "$ARTIFACTS_DIR"/*.swu 2>/dev/null | head -n 1 || true)
if [ -z "$LATEST_SWU" ] || [ ! -f "$LATEST_SWU" ]; then
    echo "ERROR: No .swu firmware packages found in $ARTIFACTS_DIR"
    echo "Please build a package first with: sh scripts/build/package-swu.sh"
    exit 1
fi

SWU_FILENAME=$(basename "$LATEST_SWU")
SWU_SIZE_BYTES=$(stat -c %s "$LATEST_SWU")
if [ -f "${LATEST_SWU}.sha256" ]; then
    SWU_SHA256=$(awk '{print $1}' "${LATEST_SWU}.sha256")
else
    SWU_SHA256=$(sha256sum "$LATEST_SWU" | awk '{print $1}')
fi
VERSION_NAME=$(echo "$SWU_FILENAME" | sed -E 's/^openke-update-(.*)\.swu$/\1/')
if [ -z "$VERSION_NAME" ] || [ "$VERSION_NAME" = "$SWU_FILENAME" ]; then
    VERSION_NAME="dev-latest"
fi

echo "======================================================="
echo " OpenKE Local Dev Update Server"
echo "======================================================="
echo " Firmware File: $SWU_FILENAME"
echo " Version:       $VERSION_NAME"
echo " Size:          $(( SWU_SIZE_BYTES / 1024 / 1024 )) MB ($SWU_SIZE_BYTES bytes)"
echo " SHA256:        $SWU_SHA256"

# Link SWU to serving directory for instant startup without disk duplication
ln -sf "$LATEST_SWU" "$SERVING_DIR/$SWU_FILENAME"
ln -sf "$LATEST_SWU" "$SERVING_DIR/openke-update.swu"

# Detect local LAN IP
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
DEV_SERVER_URL="http://${HOST_IP}:${PORT}"

# Read changelog if available
DEV_CHANGELOG=""
if [ -f "$ARTIFACTS_DIR/${SWU_FILENAME}.changelog.txt" ]; then
    DEV_CHANGELOG=$(sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' "$ARTIFACTS_DIR/${SWU_FILENAME}.changelog.txt" | awk '{if (NR>1) printf "\\n"; printf "%s", $0}')
elif [ -f "$REPO_ROOT/CHANGELOG.md" ]; then
    DEV_CHANGELOG=$(head -n 20 "$REPO_ROOT/CHANGELOG.md" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{if (NR>1) printf "\\n"; printf "%s", $0}')
else
    DEV_CHANGELOG=$(git -C "$REPO_ROOT" log --pretty=format:"• %h %s" -n 10 2>/dev/null | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{if (NR>1) printf "\\n"; printf "%s", $0}' || echo "• Local development build (${VERSION_NAME})")
fi

# Generate releases.json
cat <<EOF > "$SERVING_DIR/releases.json"
{
  "repository": "OpenKE Local Dev Server",
  "channel": "dev",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "releases": [
    {
      "version": "${VERSION_NAME}",
      "type": "nightly",
      "filename": "${SWU_FILENAME}",
      "url": "${DEV_SERVER_URL}/${SWU_FILENAME}",
      "size_bytes": ${SWU_SIZE_BYTES},
      "sha256": "${SWU_SHA256}",
      "release_notes": "Local development build served from ${HOST_IP}",
      "changelog": "${DEV_CHANGELOG}"
    }
  ]
}
EOF

echo "-------------------------------------------------------"
echo " Dev Manifest:  $DEV_SERVER_URL/releases.json"
echo " Direct SWU:    $DEV_SERVER_URL/$SWU_FILENAME"
echo "-------------------------------------------------------"

if [ -n "$PRINTER_IP" ]; then
    echo "Configuring printer at $PRINTER_IP..."
    if command -v ssh >/dev/null 2>&1; then
        echo "Pushing dev server config via SSH..."
        ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$PRINTER_IP" \
            "mkdir -p /usr/data/openke && echo 'dev_server_url=$DEV_SERVER_URL' > /usr/data/openke/openke-update.conf && echo 'dev_server_url=$DEV_SERVER_URL' > /tmp/openke-dev-url" \
            && echo "Successfully configured printer update server!" || echo "Could not SSH to printer (will rely on manual config)."
    fi
else
    echo "To configure your printer to see this dev server:"
    echo "  1. SSH to printer: root@<PRINTER_IP>"
    echo "  2. Run: echo 'dev_server_url=$DEV_SERVER_URL' > /usr/data/openke/openke-update.conf"
    echo "     (Or create /usr/data/openke-dev-url containing: $DEV_SERVER_URL)"
    echo "  3. Open the Firmware Update panel on GuppyScreen and tap 'Refresh'"
fi
echo "======================================================="
echo "Starting HTTP server on port $PORT (Press Ctrl+C to stop)..."
cd "$SERVING_DIR"
exec python3 -m http.server "$PORT"
