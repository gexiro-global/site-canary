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
    printf 'CALL\n' >> "$FAKE_CURL_LOG"
    for arg do printf 'ARG=%s\n' "$arg" >> "$FAKE_CURL_LOG"; done
    exit "${FAKE_CURL_STATUS:-0}"
    ;;
esac
if [ -n "${FAKE_SITE_KIND:-}" ]; then
  out=
  previous=
  for arg do [ "$previous" != -o ] || out=$arg; previous=$arg; done
  case $FAKE_SITE_KIND in
    timeout|dns|refused|tls) : > "$out"; exit 28 ;;
    empty) : > "$out"; printf '200\t0.01\n'; exit 0 ;;
    non2xx) printf 'OWN-SITE' > "$out"; printf '503\t0.01\n'; exit 0 ;;
    missing_time) printf 'OWN-SITE' > "$out"; printf '200\t\n'; exit 0 ;;
    boundary) printf 'OWN-SITE' > "$out"; printf '200\t1.50\n'; exit 0 ;;
  esac
fi
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
assert_contains "$OUTPUT" 'SITE-CANARY: TEST PASS'
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

FAKE_CONF=$TEST_DIR/fake.conf
printf '%s\n' 'https://probe.invalid/ | marker=OWN-SITE | max_rt=1.5' > "$FAKE_CONF"
for kind in timeout dns refused tls empty non2xx missing_time; do
  rm -f "$TEST_DIR/fake-$kind.state"
  run_capture 2 env PATH="$TEST_DIR/fake-bin:$PATH" FAKE_SITE_KIND=$kind "$CANARY" --config "$FAKE_CONF" --state "$TEST_DIR/fake-$kind.state"
  assert_contains "$OUTPUT" 'SITE-CANARY: FAIL'
done
pass 'timeouts, DNS/refusal/TLS errors, empty bodies, non-2xx, and missing timing fail closed'

run_capture 0 env PATH="$TEST_DIR/fake-bin:$PATH" FAKE_SITE_KIND=boundary "$CANARY" --config "$FAKE_CONF" --state "$TEST_DIR/boundary.state"
assert_contains "$OUTPUT" 'SITE-CANARY: PASS'
pass 'latency exactly at max_rt passes with locale-independent decimal comparison'

LITERAL=$TEST_DIR/literal.conf
printf '%s\n' "$BASE/healthy | marker=OWN-SITE | forbid=OWN,FOREIGN | forbid=SITE safe | max_rt=2" > "$LITERAL"
run_capture 2 "$CANARY" --config "$LITERAL" --state "$TEST_DIR/literal.state"
assert_contains "$OUTPUT" "forbidden marker present 'OWN'"
assert_contains "$OUTPUT" "forbidden marker present 'SITE safe'"
pass 'literal case-sensitive matching checks comma lists and every repeated forbid, including marker substrings'

EMPTY=$TEST_DIR/empty.conf
printf '%s\n' "$BASE/healthy | marker= | max_rt=2" > "$EMPTY"
run_capture 1 "$CANARY" --config "$EMPTY" --state "$TEST_DIR/empty.state"
assert_contains "$OUTPUT" 'marker must not be empty'
assert_contains "$OUTPUT" 'SITE-CANARY: ERROR'
pass 'explicit empty marker is a configuration error with summary'

CRLF=$TEST_DIR/crlf.conf
printf '  # comment\r\n\r\n%s/healthy | marker=OWN=SITE\|safe | marker=OWN-SITE\\path | marker=OWN-SITE | max_rt=2\r\n' "$BASE" > "$CRLF"
run_capture 0 "$CANARY" --config "$CRLF" --state "$TEST_DIR/crlf.state" --dry-run
assert_contains "$OUTPUT" 'marker=OWN-SITE'
pass 'comments, whitespace, CRLF, escaped pipes, equals values, and deterministic last duplicate parsing'

BACKSLASH=$TEST_DIR/backslash.conf
printf '%s\n' "$BASE/healthy | marker=OWN\\xSITE | max_rt=2" > "$BACKSLASH"
run_capture 2 "$CANARY" --config "$BACKSLASH" --state "$TEST_DIR/backslash.state"
assert_contains "$OUTPUT" 'required marker missing'
pass 'backslashes not escaping pipe or backslash remain literal'

run_capture 1 "$CANARY" --bogus
assert_contains "$OUTPUT" 'SITE-CANARY: ERROR'
pass 'unknown flags exit one and print an error summary'

: > "$FAKE_CURL_LOG"
run_capture 0 env PATH="$TEST_DIR/fake-bin:$PATH" "$CANARY" --config "$HEALTHY" --state "$TEST_DIR/dry.state" --dry-run
[ ! -s "$FAKE_CURL_LOG" ] || fail 'dry run invoked curl'
pass 'dry run performs no request or alert network calls'

EVIL=$TEST_DIR/evil.conf
# shellcheck disable=SC2016 # Deliberately literal shell metacharacters.
printf '%s\n' 'https://evil.invalid/a?x=<>&"'"'"'$` ${NO_EVAL} \| | marker=OWN-SITE | forbid=<leak>&"'"'"'$` ${NO_EVAL} | max_rt=1' > "$EVIL"
: > "$FAKE_CURL_LOG"
run_capture 2 env PATH="$TEST_DIR/fake-bin:$PATH" FAKE_SITE_KIND=empty ALERT_WEBHOOK_URL=https://webhook.invalid/secret "$CANARY" --config "$EVIL" --state "$TEST_DIR/evil.state"
LOG=$(cat "$FAKE_CURL_LOG")
assert_contains "$LOG" '\"'
# shellcheck disable=SC2016 # Assertion is deliberately literal.
assert_contains "$LOG" '${NO_EVAL}'
assert_not_contains "$OUTPUT" 'webhook.invalid/secret'
pass 'hostile URL/marker bytes are JSON encoded, remain inert, and webhook secrets stay out of output'

TG=$TEST_DIR/tg.conf
printf '%s\n' 'https://evil.invalid/<tag>&"'"'"'\\x | marker=OWN-SITE | max_rt=1' > "$TG"
: > "$FAKE_CURL_LOG"
run_capture 2 env PATH="$TEST_DIR/fake-bin:$PATH" FAKE_SITE_KIND=empty TELEGRAM_BOT_TOKEN=TOPSECRET TELEGRAM_CHAT_ID=CHATSECRET "$CANARY" --config "$TG" --state "$TEST_DIR/tg.state"
LOG=$(cat "$FAKE_CURL_LOG")
assert_contains "$LOG" '&lt;tag&gt;&amp;&quot;&#39;'
assert_contains "$LOG" '\x'
assert_not_contains "$OUTPUT" 'TOPSECRET'
assert_not_contains "$OUTPUT" 'CHATSECRET'
pass 'Telegram payload is HTML escaped and credentials never reach stdout/stderr'

ln -s "$TEST_DIR/real-state" "$TEST_DIR/link-state"
run_capture 1 "$CANARY" --config "$HEALTHY" --state "$TEST_DIR/link-state"
assert_contains "$OUTPUT" 'must not be a symlink'
mkdir "$TEST_DIR/real-dir"
ln -s "$TEST_DIR/real-dir" "$TEST_DIR/link-dir"
run_capture 1 "$CANARY" --config "$HEALTHY" --state "$TEST_DIR/link-dir/state"
assert_contains "$OUTPUT" 'symlinked directories'
run_capture 1 "$CANARY" --config "$HEALTHY" --state "$TEST_DIR/sub/../state"
assert_contains "$OUTPUT" 'traversal'
pass 'state files, parent symlinks, and traversal paths are rejected'

printf 'CORRUPT\nextra\n' > "$TEST_DIR/corrupt.state"
run_capture 0 "$CANARY" --config "$HEALTHY" --state "$TEST_DIR/corrupt.state"
assert_contains "$OUTPUT" 'SITE-CANARY: PASS'
[ "$(stat -c '%a' "$TEST_DIR/corrupt.state")" = 600 ] || fail 'state permissions are not 600'
pass 'corrupt state is unknown, safely replaced, and private'

CONCURRENT=$TEST_DIR/concurrent.state
"$CANARY" --config "$HEALTHY" --state "$CONCURRENT" > "$TEST_DIR/c1" 2>&1 & p1=$!
"$CANARY" --config "$HEALTHY" --state "$CONCURRENT" > "$TEST_DIR/c2" 2>&1 & p2=$!
wait "$p1"; wait "$p2"
[ "$(cat "$CONCURRENT")" = PASS ] || fail 'concurrent state was corrupt'
pass 'concurrent runs serialize state transitions without corruption'

printf '1..%s\n' "$PASS_COUNT"
