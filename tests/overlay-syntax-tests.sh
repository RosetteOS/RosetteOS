#!/bin/sh
#
# Validates that all shell scripts and init.d scripts in the overlay
# are free of syntax errors (sh -n).
#
# Usage: sh tests/overlay-syntax-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OVERLAY="$ROOT/scripts/build/overlay"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

# Check all init.d scripts
for script in "$OVERLAY"/etc/init.d/*; do
	[ -f "$script" ] || continue
	if sh -n "$script" 2>/dev/null; then
		pass
	else
		fail "syntax error in $(basename "$script")"
	fi
done

# Check all other shell scripts in overlay
for script in $(find "$OVERLAY" -type f \( -name "*.sh" -o -perm -111 \)); do
	[ -f "$script" ] || continue
	case "$script" in
		*/etc/init.d/*|*.py|*.so|*.png|*.json|*.txt|*.cfg|*.conf|*.service|*.rules|*.env|*.md) continue ;;
	esac
	head -n1 "$script" 2>/dev/null | grep -qE '^#!/(bin|usr/bin)/(sh|ash|bash)' || continue
	if sh -n "$script" 2>/dev/null; then
		pass
	else
		fail "syntax error in $script"
	fi
done

echo "overlay-syntax-tests: $PASS init.d/shell scripts passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
