#!/bin/sh
#
# Unified test suite runner for RosetteOS.
# Runs all offline unit, integration, and security/regression test suites.
#
# Usage:
#   tests/run-all.sh              # Run all test suites
#   tests/run-all.sh <filter>     # Run only test suites matching <filter> (e.g. 'config', 'appstore')
#   tests/run-all.sh -v           # Verbose mode (print test output in real-time)
#

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

cd "$REPO_ROOT"

FILTER=""
VERBOSE=0

for arg in "$@"; do
	case "$arg" in
		-v|--verbose)
			VERBOSE=1
			;;
		*)
			FILTER="$arg"
			;;
	esac
done

# Color formatting
if [ -t 1 ]; then
	C_GREEN="\033[32m"
	C_RED="\033[31m"
	C_BLUE="\033[34m"
	C_BOLD="\033[1m"
	C_RESET="\033[0m"
else
	C_GREEN=""
	C_RED=""
	C_BLUE=""
	C_BOLD=""
	C_RESET=""
fi

TOTAL=0
PASSED=0
FAILED=0
FAILED_NAMES=""

echo "${C_BOLD}=== Running RosetteOS Test Suites ===${C_RESET}"
[ -n "$FILTER" ] && echo "Filter: '$FILTER'"
echo ""

START_ALL=$(date +%s)

run_test() {
	_script="$1"
	_name=$(basename "$_script")

	# If a filter is specified, skip non-matching tests
	if [ -n "$FILTER" ]; then
		case "$_name" in
			*"$FILTER"*) ;;
			*) return 0 ;;
		esac
	fi

	TOTAL=$((TOTAL + 1))
	printf "  %-50s ... " "$_name"

	_t0=$(date +%s)
	if [ "$VERBOSE" -eq 1 ]; then
		echo ""
		if "$_script"; then
			_t1=$(date +%s)
			printf "%b[PASS]%b (%ds)\n" "$C_GREEN" "$C_RESET" "$((_t1 - _t0))"
			PASSED=$((PASSED + 1))
		else
			_rc=$?
			_t1=$(date +%s)
			printf "%b[FAIL (rc=%d)]%b (%ds)\n" "$C_RED" "$_rc" "$C_RESET" "$((_t1 - _t0))"
			FAILED=$((FAILED + 1))
			FAILED_NAMES="$FAILED_NAMES $_name"
		fi
	else
		_tmp=$(mktemp)
		if "$_script" >"$_tmp" 2>&1; then
			_t1=$(date +%s)
			printf "%bPASS%b (%ds)\n" "$C_GREEN" "$C_RESET" "$((_t1 - _t0))"
			PASSED=$((PASSED + 1))
			rm -f "$_tmp"
		else
			_rc=$?
			_t1=$(date +%s)
			printf "%bFAIL (rc=%d)%b (%ds)\n" "$C_RED" "$_rc" "$C_RESET" "$((_t1 - _t0))"
			FAILED=$((FAILED + 1))
			FAILED_NAMES="$FAILED_NAMES $_name"
			echo "    --- Failure Output ---"
			sed 's/^/    /' "$_tmp" | tail -n 25
			echo "    ----------------------"
			rm -f "$_tmp"
		fi
	fi
}

# Run all test scripts in tests/ (excluding run-all.sh)
for test_file in tests/*.sh tests/*.py; do
	[ -f "$test_file" ] || continue
	[ "$test_file" = "tests/run-all.sh" ] && continue
	run_test "$test_file"
done

END_ALL=$(date +%s)
ELAPSED_ALL=$((END_ALL - START_ALL))

echo ""
echo "${C_BOLD}============================================================${C_RESET}"
printf "${C_BOLD}Test Summary (%ds): %b%d passed%b, " "$ELAPSED_ALL" "$C_GREEN" "$PASSED" "$C_RESET"
if [ "$FAILED" -eq 0 ]; then
	printf "%b0 failed%b across %d suites\n" "$C_GREEN" "$C_RESET" "$TOTAL"
	echo "${C_BOLD}============================================================${C_RESET}"
	exit 0
else
	printf "%b%d failed%b across %d suites\n" "$C_RED" "$FAILED" "$C_RESET" "$TOTAL"
	echo "Failed suites:$FAILED_NAMES"
	echo "${C_BOLD}============================================================${C_RESET}"
	exit 1
fi
