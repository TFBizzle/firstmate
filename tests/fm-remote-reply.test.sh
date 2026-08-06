#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
cleanup() {
  local worker_pid='' wait_attempt=0
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
    while kill -0 "$worker_pid" 2>/dev/null && [ "$wait_attempt" -lt 100 ]; do
      wait_attempt=$((wait_attempt + 1))
      sleep 0.05
    done
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
# Each generation below references a remote document that is deliberately not
# created until after that generation is captured. The runner's auto-apply then
# fails for real on the unavailable document, which is what keeps the handler's
# own manual path - and the crash window it exists for - under test here. The
# successful auto-apply path is covered by its own case further down.
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef]: build verified (data/reply/report.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
assert_grep "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue" "runner did not publish the normalized remote-reply event"
assert_no_grep 'build verified' "$PARENT/state/.wake-queue" "reply payload leaked into the event queue"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
assert_absent "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "a capture whose auto-apply failed was acknowledged anyway"
assert_absent "$PARENT/state/ios.status" \
  "a capture whose auto-apply failed still touched the parent status log"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"

rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=1' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not commit the reply before retry"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

printf 'working [corr=1111111111111111]: second generation (data/reply/second.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "second reply generation was not captured"
printf '# Second\n' > "$REMOTE/data/reply/second.md"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
printf 'done [corr=2222222222222222]: third generation (data/reply/third.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "third reply generation was not captured"
printf '# Third\n' > "$REMOTE/data/reply/third.md"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ADAPTER" handle ios 3 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 2' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
pass "later generations cannot invalidate an unacknowledged ingested result"

# A remote secondmate answers only through this relay, and applying that answer
# carries no judgement, so it must happen by code on the ordinary capture path
# rather than depending on the handler running the adapter. These two cases
# drive that real path end to end: the reply reaches the secondmate's local
# status mirror, settles the parent's own pending-reply expectation, and stops
# the answered request from surfacing as an open decision.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
export FM_PENDING_REPLY_GRACE_SECS=0
PENDING_STATE="$PARENT/state"

open_request() {  # <summary> -> corr
  local corr
  corr=$(fm_pending_reply_create "$PARENT" "$PENDING_STATE" ios "$1") || return 1
  fm_pending_reply_mark_delivered "$PENDING_STATE" "$corr" || return 1
  fm_pending_reply_mark_turn_completed "$PENDING_STATE" "$corr" request || return 1
  printf '%s' "$corr"
}

# The remote answers on its parent-replies channel and the runner captures it,
# exactly as an unattended relay does. No handler step is simulated.
relay_reply() {  # <corr> <sequence>
  printf 'done [corr=%s]: release chain published\n' "$1" \
    >> "$REMOTE/state/parent-replies.status"
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
    || fail "the relay did not capture the correlated reply"
  assert_present "$PARENT/state/procevent-inbox/$SID.$2.result" \
    "the correlated reply was not durably captured"
}

PENDING_OPEN=$(open_request "publish the release chain")
[ -n "$PENDING_OPEN" ] || fail "no pending-reply expectation was created for the remote request"
relay_reply "$PENDING_OPEN" 4
assert_grep "done [corr=$PENDING_OPEN]" "$PARENT/state/ios.status" \
  "the captured reply never reached the secondmate's local status mirror"
assert_present "$PARENT/state/procevent-inbox/$SID.4.handled" \
  "the applied reply was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the reply left the relay unarmed for the next one"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PENDING_STATE" "$PENDING_OPEN")" phase)" = resolved ] \
  || fail "the answered request was left unresolved"
fm_pending_reply_tick "$PENDING_STATE" || fail "supervision tick failed"
assert_no_grep "pending-reply-missed" "$PARENT/state/ios.status" \
  "an answered remote request still escalated as a missed report"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$PENDING_OPEN" "an answered remote request surfaces as an open decision"
pass "a captured remote reply is applied by the relay itself and settles its request"

# The same reply arriving after the request already escalated must also retire
# the decision that escalation opened, or the settled request keeps surfacing in
# every later fold.
PENDING_LATE=$(open_request "confirm the notarization")
FM_PENDING_REPLY_SEND_HOOK=true fm_pending_reply_send_recovery "$PENDING_STATE" "$PENDING_LATE" \
  || fail "the one automatic recovery repost was not sent"
fm_pending_reply_mark_turn_completed "$PENDING_STATE" "$PENDING_LATE" recovery
fm_pending_reply_maybe_escalate "$PENDING_STATE" "$PENDING_LATE" \
  || fail "a missed remote report did not escalate"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$PENDING_LATE" "the missed report did not open a durable decision"

relay_reply "$PENDING_LATE" 5
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$PENDING_STATE" "$PENDING_LATE")" phase)" = resolved ] \
  || fail "the late reply left its escalated request unresolved"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$PENDING_LATE" "the settled request still surfaces as an open decision"
[ "$(grep -Fc "pending-reply-missed: task=ios pending-reply-id=$PENDING_LATE" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "the settled request re-escalated its missed-report line"
# Later passes must neither re-open it nor close it a second time.
fm_pending_reply_tick "$PENDING_STATE" || fail "later supervision tick failed"
fm_pending_reply_tick "$PENDING_STATE" || fail "later supervision tick failed"
[ "$(grep -Fc "pending-reply-resolved: task=ios pending-reply-id=$PENDING_LATE" "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "the settled request was closed more than once"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$PENDING_LATE" "the settled request re-opened on a later pass"
unset FM_PENDING_REPLY_GRACE_SECS
pass "a reply that arrives after escalation resolves it and clears the open decision"

# A digest-valid but uncorrelated line is still rejected at the public ingest
# boundary. Recalculate its payload commitment so the behavioral assertion is
# specifically about status validation, not incidental digest failure.
BAD_RESULT="$TMP_ROOT/bad.result"
cp "$RESULT" "$BAD_RESULT"
boundary=$(grep -n -m 1 '^$' "$BAD_RESULT" | cut -d: -f1)
tail -n "+$((boundary + 1))" "$BAD_RESULT" \
  | sed 's/corr=0123456789abcdef/no-correlation/' > "$TMP_ROOT/bad.payload"
bad_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/bad.payload" | tr -d ' ')
bad_hash=$(sha256_file "$TMP_ROOT/bad.payload")
head -n "$boundary" "$BAD_RESULT" \
  | sed "s/^payload_sha256=.*/payload_sha256=$bad_hash/;s/^payload_bytes=.*/payload_bytes=$bad_bytes/" \
  > "$TMP_ROOT/bad.header"
cat "$TMP_ROOT/bad.header" "$TMP_ROOT/bad.payload" > "$BAD_RESULT"
if remote_env "$ADAPTER" ingest ios "$BAD_RESULT" >/dev/null 2>&1; then
  fail "ingest accepted a status line with no correlation token"
fi
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "invalid ingest disturbed the accepted parent status line"
pass "ingest rejects uncorrelated payload even when its transport digest is valid"

# The adapter re-armed at the committed cursor. Truncation is detected from the
# next blocking source and escalated once; it is never silently treated as a new
# log or re-armed past the break.
printf 'failed [corr=fedcba9876543210]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 &
RUNNER=$!
wait "$RUNNER" || fail "continuity break was not captured as a structured result"
RESULT_SIX=$(find "$PARENT/state/procevent-inbox" -name "$SID.6.result" -print -quit)
[ -n "$RESULT_SIX" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_SIX")" = continuity-broken ] \
  || fail "truncated source was not classified as a continuity break"
set +e
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" > "$TMP_ROOT/handle-four.out" 2>&1
handle_rc=$?
set -e
[ "$handle_rc" -eq 3 ] || fail "continuity handling returned an unexpected status: $handle_rc"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "continuity break did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "continuity break was re-armed without an operator rebase"
remote_env "$ADAPTER" ingest ios "$RESULT_SIX" >/dev/null 2>&1 || true
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity replay duplicated the escalation"
pass "truncation is detected, escalated once, and not silently rebased"

rm -f "$PARENT/state/procevent-inbox/$SID.6.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
pass "remote reply retirement quiesces and refuses unhandled captured results"

echo "ALL TESTS PASSED"
