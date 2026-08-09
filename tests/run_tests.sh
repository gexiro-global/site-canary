#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
CANARY=$ROOT/site-canary
REAL_CURL=$(command -v curl)
TMP_BASE=${TMPDIR:-/tmp}
TEST_DIR=$(mktemp -d "$TMP_BASE/site-canary-tests.XXXXXX")
SERVER_PID=
PASS_COUNT=0

cleanup() {
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || :
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'ok %s - %s\n' "$PASS_COUNT" "$*"; }
assert_contains() { printf '%s' "$1" | grep -Fq -- "$2" || fail "expected output to contain: $2"; }
assert_not_contains() { if printf '%s' "$1" | grep -Fq -- "$2"; then fail "expected output not to contain: $2"; fi; }

run_capture() {
  expected=$1
  shift
  set +e
  OUTPUT=$("$@" 2>&1)
  STATUS=$?
  set -e
  [ "$STATUS" -eq "$expected" ] || fail "expected exit $expected, got $STATUS; output: $OUTPUT"
}

python3 "$ROOT/tests/fixture_server.py" "$TEST_DIR/port" &
SERVER_PID=$!
i=0
while [ ! -s "$TEST_DIR/port" ]; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail 'fixture server did not start'
  sleep 0.02
done
PORT=$(sed -n '1p' "$TEST_DIR/port")
BASE=http://127.0.0.1:$PORT

mkdir "$TEST_DIR/fake-bin"
cat > "$TEST_DIR/fake-bin/curl" <<'EOF'
#!/bin/sh
case " $* " in
  *webhook.invalid*|*api.telegram.org*)
    printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
    exit "${FAKE_CURL_STATUS:-0}"
    ;;
esac
exec "$REAL_CURL" "$@"
EOF
chmod +x "$TEST_DIR/fake-bin/curl"
FAKE_CURL_LOG=$TEST_DIR/curl.log
export REAL_CURL FAKE_CURL_LOG

HEALTHY=$TEST_DIR/healthy.conf
printf '%s\n' "$BASE/healthy | marker=OWN-SITE | forbid=FOREIGN-TENANT | max_rt=2" > "$HEALTHY"
STATE=$TEST_DIR/state

run_capture 0 "$CANARY" --config "$HEALTHY" --state "$STATE"
assert_contains "$OUTPUT" 'SITE-CANARY: PASS'
assert_not_contains "$OUTPUT" 'RECOVERED'
pass 'healthy status, marker, forbidden absence, and latency pass'

run_capture 0 "$CANARY" --config "$HEALTHY" --state "$STATE"
assert_not_contains "$OUTPUT" 'RECOVERED'
assert_not_contains "$OUTPUT" 'SITE-CANARY ALERT'
pass 'PASS to PASS is silent apart from summary'

FAILURES=$TEST_DIR/failures.conf
{
  printf '%s\n' "$BASE/missing | marker=OWN-SITE | max_rt=2"
  printf '%s\n' "$BASE/leak | marker=OWN-SITE | forbid=FOREIGN-TENANT | max_rt=2"
  printf '%s\n' "$BASE/wrong-status | expect=200 | marker=OWN-SITE | max_rt=2"
  printf '%s\n' "$BASE/slow | marker=OWN-SITE | max_rt=0.05"
} > "$FAILURES"
run_capture 2 "$CANARY" --config "$FAILURES" --state "$STATE"
assert_contains "$OUTPUT" 'required marker missing'
assert_contains "$OUTPUT" 'CROSS-TENANT LEAK'
assert_contains "$OUTPUT" 'HTTP 503 (expected 200)'
assert_contains "$OUTPUT" 'latency'
assert_contains "$OUTPUT" 'SITE-CANARY: FAIL'
pass 'all four failure classifications are reported in one alert'

run_capture 2 "$CANARY" --config "$FAILURES" --state "$STATE"
assert_not_contains "$OUTPUT" 'SITE-CANARY ALERT'
assert_not_contains "$OUTPUT" 'CROSS-TENANT LEAK'
assert_contains "$OUTPUT" 'SITE-CANARY: FAIL'
pass 'FAIL to FAIL suppresses repeat alert'

run_capture 0 "$CANARY" --config "$HEALTHY" --state "$STATE"
assert_contains "$OUTPUT" 'SITE-CANARY RECOVERED'
assert_contains "$OUTPUT" 'SITE-CANARY: PASS'
pass 'FAIL to PASS emits RECOVERED'

run_capture 0 "$CANARY" --config "$HEALTHY" --state "$STATE" --dry-run
assert_contains "$OUTPUT" 'SITE-CANARY: DRY-RUN'
assert_contains "$OUTPUT" 'marker=OWN-SITE'
assert_not_contains "$OUTPUT" 'SITE-CANARY: PASS ('
pass 'dry run resolves config without checking'

: > "$FAKE_CURL_LOG"
run_capture 0 env PATH="$TEST_DIR/fake-bin:$PATH" ALERT_WEBHOOK_URL=https://webhook.invalid/accept "$CANARY" --test
assert_contains "$OUTPUT" 'SITE-CANARY TEST'
[ -s "$FAKE_CURL_LOG" ] || fail 'test alert did not call fake webhook transport'
assert_not_contains "$(cat "$FAKE_CURL_LOG")" 'TELEGRAM_BOT_TOKEN'
pass 'test alert uses stubbed transport and exits zero'

run_capture 1 "$CANARY" --config "$TEST_DIR/missing.conf" --state "$STATE"
assert_contains "$OUTPUT" 'config file is not readable'
pass 'configuration errors exit one'

DEFAULTS=$TEST_DIR/defaults.conf
printf '%s\n' "$BASE/healthy" > "$DEFAULTS"
run_capture 2 "$CANARY" --config "$DEFAULTS" --state "$TEST_DIR/default-state"
assert_contains "$OUTPUT" 'required marker missing'
pass 'URL-only config derives hostname marker and defaults expected status'

printf '1..%s\n' "$PASS_COUNT"
