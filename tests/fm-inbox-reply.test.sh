#!/usr/bin/env bash
# tests/fm-inbox-reply.test.sh - bin/fm-inbox.sh's reply record: one durable answer
# per known note id, written in the header's id/at/seq/--/body format.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INBOX_SH="$ROOT/bin/fm-inbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-inbox-reply)

new_home() {  # <name>: a fresh home with one queued note; prints "<home> <id>"
  local home="$TMP_ROOT/$1" out id
  mkdir -p "$home/state" "$home/data"
  out=$(FM_HOME="$home" "$INBOX_SH" note "please answer me" 2>&1) \
    || fail "note failed: $out"
  id=$(printf '%s\n' "$out" | sed -n 's/^queued //p' | head -n 1)
  [ -n "$id" ] || fail "note printed no id: $out"
  printf '%s %s\n' "$home" "$id"
}

test_reply_writes_record() {
  local home id out file
  read -r home id < <(new_home write)
  out=$(printf 'line one\nline two\n' | FM_HOME="$home" "$INBOX_SH" reply "$id" - 2>&1) \
    || fail "reply failed: $out"
  assert_contains "$out" "replied $id" "reply confirms the id"
  file="$home/state/inbox/.replies/$id"
  assert_present "$file" "reply record exists"
  [ "$(sed -n 1p "$file")" = "id=$id" ] || fail "first line is id"
  sed -n 2p "$file" | grep -Eq '^at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
    || fail "second line is a UTC at= stamp"
  [ "$(sed -n 3p "$file")" = "seq=1" ] || fail "third line is seq=1"
  [ "$(sed -n 4p "$file")" = "--" ] || fail "fourth line is the separator"
  [ "$(sed -n '5,$p' "$file")" = $'line one\nline two' ] || fail "body is byte-exact"
  [ "$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")" = 600 ] \
    || fail "reply record is private"
  pass "reply writes the record in the inbox reply format"
}

test_handled_note_and_sequence() {
  local home id id2 out
  read -r home id < <(new_home handled)
  FM_HOME="$home" "$INBOX_SH" drain --ack "$id" >/dev/null || fail "ack failed"
  out=$(FM_HOME="$home" "$INBOX_SH" reply "$id" "first" 2>&1) \
    || fail "reply to a handled note failed: $out"
  id2=$(FM_HOME="$home" "$INBOX_SH" note "second" 2>/dev/null | sed -n 's/^queued //p')
  FM_HOME="$home" "$INBOX_SH" reply "$id2" "second" >/dev/null 2>&1 || fail "second note reply failed"
  [ "$(sed -n 3p "$home/state/inbox/.replies/$id2")" = "seq=2" ] || fail "sequence advances"
  pass "reply accepts a handled note and advances the sequence"
}

test_second_reply_refused() {
  local home id out code
  read -r home id < <(new_home twice)
  FM_HOME="$home" "$INBOX_SH" reply "$id" "first" >/dev/null 2>&1 || fail "first reply failed"
  out=$(FM_HOME="$home" "$INBOX_SH" reply "$id" "second" 2>&1); code=$?
  expect_code 1 "$code" "second reply"
  assert_contains "$out" "reply already recorded" "second reply names the refusal"
  assert_grep "first" "$home/state/inbox/.replies/$id" "first reply is kept"
  pass "a second reply to the same note is refused"
}

test_unknown_id_refused() {
  local home id out code
  read -r home id < <(new_home unknown)
  out=$(FM_HOME="$home" "$INBOX_SH" reply "1-nosuch" "hi" 2>&1); code=$?
  expect_code 1 "$code" "unknown id"
  assert_contains "$out" "no such note" "unknown id names the refusal"
  out=$(FM_HOME="$home" "$INBOX_SH" reply "../x" "hi" 2>&1); code=$?
  expect_code 1 "$code" "path id"
  assert_absent "$home/state/inbox/.replies/1-nosuch" "no record for unknown id"
  pass "a reply to an unknown note id is refused"
}

test_empty_body_refused() {
  local home id out code
  read -r home id < <(new_home empty)
  out=$(printf '  \n' | FM_HOME="$home" "$INBOX_SH" reply "$id" - 2>&1); code=$?
  expect_code 1 "$code" "empty body"
  assert_contains "$out" "empty reply" "empty body names the refusal"
  assert_absent "$home/state/inbox/.replies/$id" "no record for empty body"
  pass "an empty reply body is refused"
}

test_reply_writes_record
test_handled_note_and_sequence
test_second_reply_refused
test_unknown_id_refused
test_empty_body_refused
