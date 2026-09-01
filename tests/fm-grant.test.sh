#!/usr/bin/env bash
# Behavior tests for bin/fm-grant.sh - the captain-authorized grant vault.
#
# Every case runs against fakebin `security` and `av` shims plus an isolated
# FM_GRANT_STATE_DIR, so no test ever touches the real login Keychain or fires
# a real av approval dialog. The suite pins the public contract:
#   - names failing ^[A-Z][A-Z0-9_]*$ are hard-rejected by every subcommand,
#     --reason is required, a grant needs one explicit bound, and there is no
#     public get.
#   - grant imports through the hidden `_store` shape
#     (`av inject +KEY -- fm-grant.sh _store KEY`), announces the permanent
#     custody downgrade, stores the exact bytes minus one trailing newline,
#     and lands state 0600 inside a 0700 grants dir.
#   - exec injects the Keychain value into the child env only, decrements one
#     use per retrieval, and combined uses+deadline grants trip on whichever
#     limit comes first while the Keychain item stays.
#   - the no-grant fallback execs `av inject +KEY... -- cmd` directly, prints
#     one loud stderr line, consumes nothing, and the value never transits
#     fm-grant.
#   - revoke ends the window but keeps the item; forget wipes both.
#   - concurrent execs decrement exactly once each (the mkdir-spinlock proof).
#   - grant-shape warnings (--permanent, uses>100, until>30d, consequence-
#     listed names) warn without blocking, and a plain API key stays quiet.
#   - no secret value ever appears in fm-grant stdout/stderr, grant state, the
#     grant log, or recorded av argv.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_GRANT="$ROOT/bin/fm-grant.sh"
TMP_ROOT=$(fm_test_tmproot fm-grant-tests)

SECRET='s3cr3t-value-du2ok9-never-in-output'

# --- shared fakebin shims ----------------------------------------------------
#
# Both shims are pure functions of per-case env (FAKE_KEYCHAIN, FAKE_AV_SECRETS,
# AV_LOG), so one shared fakebin dir serves every case.

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# Fake macOS `security` backed by $FAKE_KEYCHAIN/<account> files holding the
# exact stored bytes. find -w prints the value plus the real tool's trailing
# newline; a missing item exits 44 like errSecItemNotFound.
cat > "$FAKEBIN/security" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${1-}
[ $# -eq 0 ] || shift
service= account= find_w=0 add_value= have_add_value=0
case "$cmd" in
  find-generic-password|add-generic-password|delete-generic-password) : ;;
  *) echo "fake security: unsupported command $cmd" >&2; exit 64 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -s) service=$2; shift 2 ;;
    -a) account=$2; shift 2 ;;
    -U) shift ;;
    -w)
      if [ "$cmd" = add-generic-password ]; then
        add_value=$2; have_add_value=1; shift 2
      else
        find_w=1; shift
      fi
      ;;
    *) shift ;;
  esac
done
[ "$service" = firstmate-grant ] || { echo "fake security: unexpected service '$service'" >&2; exit 64; }
[ -n "$account" ] || { echo "fake security: missing account" >&2; exit 64; }
item="$FAKE_KEYCHAIN/$account"
case "$cmd" in
  find-generic-password)
    [ -f "$item" ] || exit 44
    if [ "$find_w" = 1 ]; then
      cat "$item"
      printf '\n'
    fi
    ;;
  add-generic-password)
    [ "$have_add_value" = 1 ] || { echo "fake security: add without -w value" >&2; exit 64; }
    mkdir -p "$FAKE_KEYCHAIN"
    printf '%s' "$add_value" > "$item"
    ;;
  delete-generic-password)
    [ -f "$item" ] || exit 44
    rm -f "$item"
    ;;
esac
exit 0
SH

# Fake `av`: records its argv to $AV_LOG, then emulates `inject +KEY... -- cmd`
# by injecting $FAKE_AV_SECRETS/<KEY> bytes (trailing newline preserved) into
# the child env and exec'ing the command.
cat > "$FAKEBIN/av" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$AV_LOG"
[ "${1-}" = inject ] || { echo "fake av: unsupported command ${1-}" >&2; exit 64; }
shift
pairs=()
while [ $# -gt 0 ]; do
  case "$1" in
    +*)
      k=${1#+}
      f="$FAKE_AV_SECRETS/$k"
      [ -f "$f" ] || { echo "fake av: no fixture secret for $k" >&2; exit 65; }
      v=$(cat "$f"; printf x)
      v=${v%x}
      pairs+=("$k=$v")
      shift
      ;;
    --) shift; break ;;
    *) echo "fake av: unexpected arg $1" >&2; exit 64 ;;
  esac
done
[ $# -gt 0 ] || { echo "fake av: missing command" >&2; exit 64; }
exec env ${pairs[@]+"${pairs[@]}"} "$@"
SH

chmod +x "$FAKEBIN/security" "$FAKEBIN/av"

# --- case fixtures and helpers -----------------------------------------------

CASE_N=0
new_case() {
  CASE_N=$((CASE_N + 1))
  local d="$TMP_ROOT/case-$CASE_N"
  mkdir -p "$d/state" "$d/keychain" "$d/avsecrets"
  printf '%s\n' "$d"
}

# fmg <case-dir> <arg>... - run fm-grant against the case's shims and isolated
# state; stdout lands in <case>/out, stderr in <case>/err, exit code in RC.
RC=0
fmg() {
  local d=$1
  shift
  PATH="$FAKEBIN:$PATH" \
    FAKE_KEYCHAIN="$d/keychain" \
    FAKE_AV_SECRETS="$d/avsecrets" \
    AV_LOG="$d/av.log" \
    FM_HOME="$d" \
    FM_GRANT_STATE_DIR="$d/state" \
    "$FM_GRANT" "$@" > "$d/out" 2> "$d/err"
  RC=$?
}

grant_field() {  # <case> <KEY> <field>
  sed -n "s/^$3=//p" "$1/state/grants/$2" 2>/dev/null | sed -n 1p
}

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

av_lines() {  # <case> - how many av invocations were recorded
  if [ -f "$1/av.log" ]; then
    wc -l < "$1/av.log"
  else
    printf '0\n'
  fi
}

assert_no_value_leak() {  # <case> <value> <label>
  local d=$1 v=$2 label=$3 f
  for f in "$d/out" "$d/err" "$d/state/grants.log" "$d/av.log"; do
    [ -f "$f" ] || continue
    assert_no_grep "$v" "$f" "$label: value leaked into ${f#"$d"/}"
  done
  if [ -d "$d/state/grants" ] && grep -rF -- "$v" "$d/state/grants" >/dev/null 2>&1; then
    fail "$label: value leaked into grant state"
  fi
}

# --- name validation, required flags, no public get -------------------------

d=$(new_case)
printf '%s' "$SECRET" > "$d/avsecrets/GOOD_KEY"

fmg "$d" grant lower_key --uses 1 --reason ok
expect_code 1 "$RC" 'lowercase name rejected'
assert_grep 'invalid secret name' "$d/err" 'grant names the validation failure'
fmg "$d" grant 'BAD-DASH' --uses 1 --reason ok
expect_code 1 "$RC" 'dashed name rejected'
fmg "$d" grant '1LEADING' --uses 1 --reason ok
expect_code 1 "$RC" 'digit-led name rejected'
fmg "$d" exec 'BAD;INJ' -- /usr/bin/true
expect_code 1 "$RC" 'exec rejects a shell-metacharacter name'
fmg "$d" revoke 'bad name'
expect_code 1 "$RC" 'revoke rejects an invalid name'
fmg "$d" forget 'x/y'
expect_code 1 "$RC" 'forget rejects an invalid name'
fmg "$d" _store 'bad name'
expect_code 1 "$RC" '_store rejects an invalid name'
fmg "$d" _store GOOD_KEY
expect_code 1 "$RC" '_store without the env value fails'
fmg "$d" grant GOOD_KEY --uses 1
expect_code 1 "$RC" 'grant without --reason rejected'
assert_grep '--reason' "$d/err" 'grant names the missing --reason'
fmg "$d" grant GOOD_KEY --reason ok
expect_code 1 "$RC" 'grant without any explicit bound rejected'
fmg "$d" get GOOD_KEY
expect_code 1 "$RC" 'no public get subcommand'
assert_absent "$d/state/grants/GOOD_KEY" 'rejected grants write no state'
assert_absent "$d/av.log" 'rejected grants never reach av'
fmg "$d" status
expect_code 0 "$RC" 'status works with nothing imported'
assert_grep 'NOT a security control' "$d/out" 'status states the honest identity'
assert_grep 'No keys imported' "$d/out" 'empty status says so'
pass 'validation hard-rejects bad names, missing --reason, missing bounds, and public get'

# --- import via the hidden _store shape --------------------------------------

d=$(new_case)
# The fixture value carries a trailing newline that import must strip.
printf '%s\n' "$SECRET" > "$d/avsecrets/API_TOKEN"
printf '%s' "$SECRET" > "$d/expected-bytes"

fmg "$d" grant API_TOKEN --uses 3 --reason 'captain: stop prompting for linear'
expect_code 0 "$RC" 'grant with first-time import succeeds'
assert_grep "inject +API_TOKEN -- $FM_GRANT _store API_TOKEN" "$d/av.log" 'import goes through the av _store shape'
assert_present "$d/keychain/API_TOKEN" 'import lands the Keychain item'
cmp -s "$d/keychain/API_TOKEN" "$d/expected-bytes" || fail 'stored bytes are the exact value minus one trailing newline'
assert_grep 'ANY same-user process' "$d/err" 'grant announces the custody downgrade'
assert_grep 'av approval dialog' "$d/err" 'grant says a dialog may be waiting'
[ "$(file_mode "$d/state/grants/API_TOKEN")" = 600 ] || fail 'grant state file is 0600'
[ "$(file_mode "$d/state/grants")" = 700 ] || fail 'grants dir is 0700'
[ "$(grant_field "$d" API_TOKEN uses_left)" = 3 ] || fail 'uses_left recorded'
[ "$(grant_field "$d" API_TOKEN imported_from)" = av ] || fail 'imported_from recorded'
assert_grep 'captain: stop prompting for linear' "$d/state/grants/API_TOKEN" 'reason recorded in state'
assert_grep 'grant API_TOKEN uses=3' "$d/state/grants.log" 'grant logged'
assert_grep 'import API_TOKEN via=av' "$d/state/grants.log" 'import logged'
assert_no_value_leak "$d" "$SECRET" 'import case'

av_before=$(av_lines "$d")
fmg "$d" grant API_TOKEN --uses 5 --reason 'captain: widen it'
expect_code 0 "$RC" 're-grant succeeds'
[ "$(av_lines "$d")" -eq "$av_before" ] || fail 're-grant of an imported key skips av'
[ "$(grant_field "$d" API_TOKEN uses_left)" = 5 ] || fail 're-grant replaces the bounds'
pass 'grant imports via the _store shape, stores exact bytes, and lands 0600/0700 state'

# --- exec decrements, injects, and exhaustion falls back ---------------------

d=$(new_case)
printf '%s' "$SECRET" > "$d/avsecrets/API_TOKEN"
printf '%s' "$SECRET" > "$d/expected-bytes"
fmg "$d" grant API_TOKEN --uses 2 --reason 'captain: two uses'
expect_code 0 "$RC" 'setup grant for exec case'

# shellcheck disable=SC2016 # the child shell, not this test, expands the env var
fmg "$d" exec API_TOKEN -- /bin/sh -c 'printf %s "$API_TOKEN" > "$1"' _ "$d/child-out"
expect_code 0 "$RC" 'exec with an active grant succeeds'
cmp -s "$d/child-out" "$d/expected-bytes" || fail 'child received the value via its env'
[ "$(grant_field "$d" API_TOKEN uses_left)" = 1 ] || fail 'one use consumed'
[ "$(av_lines "$d")" -eq 1 ] || fail 'granted exec never calls av'
assert_grep 'use API_TOKEN uses_left=1' "$d/state/grants.log" 'use receipt logged'

fmg "$d" exec API_TOKEN -- /usr/bin/true
expect_code 0 "$RC" 'second exec consumes the last use'
[ "$(grant_field "$d" API_TOKEN uses_left)" = 0 ] || fail 'last use consumed'
assert_grep 'expire API_TOKEN limit=uses' "$d/state/grants.log" 'exhaustion logged as expiry'

# shellcheck disable=SC2016 # the child shell, not this test, expands the env var
fmg "$d" exec API_TOKEN -- /bin/sh -c 'printf %s "$API_TOKEN" > "$1"' _ "$d/child-out-fb"
expect_code 0 "$RC" 'exhausted exec still completes through av'
cmp -s "$d/child-out-fb" "$d/expected-bytes" || fail 'fallback child got the value from av'
assert_grep 'no active grant' "$d/err" 'fallback is announced loudly on stderr'
assert_grep 'inject +API_TOKEN -- /bin/sh' "$d/av.log" 'fallback execs av inject with the command directly'
assert_grep 'fallback ungranted=API_TOKEN' "$d/state/grants.log" 'fallback logged'
assert_no_value_leak "$d" "$SECRET" 'exec case'
pass 'exec injects into the child env, decrements one use per retrieval, and exhausts to av'

# --- a failed/empty read must NOT consume a use ------------------------------
# Regression: exec used to consume a use in one loop and read the secret in a
# separate later loop, so a "forget" racing that window burned a use without
# ever delivering the value. The read now precedes the consume under the same
# per-key lock, so a vanished value falls back to av while the grant is intact.

d=$(new_case)
printf '%s' "$SECRET" > "$d/avsecrets/RACE_KEY"
printf '%s' "$SECRET" > "$d/expected-bytes"
fmg "$d" grant RACE_KEY --uses 2 --reason 'captain: race window'
expect_code 0 "$RC" 'setup grant for read-race case'
[ "$(grant_field "$d" RACE_KEY uses_left)" = 2 ] || fail 'read-race grant starts with two uses'

# The value disappears from the Keychain after the active grant still exists -
# exactly the forget-vs-read race the bug burned a use on.
rm -f "$d/keychain/RACE_KEY"

# shellcheck disable=SC2016 # the child shell, not this test, expands the env var
fmg "$d" exec RACE_KEY -- /bin/sh -c 'printf %s "$RACE_KEY" > "$1"' _ "$d/child-out"
expect_code 0 "$RC" 'exec with a vanished value still completes through av'
cmp -s "$d/child-out" "$d/expected-bytes" || fail 'fallback child got the value from av'
[ "$(grant_field "$d" RACE_KEY uses_left)" = 2 ] || fail 'a failed/empty read consumes no use'
assert_no_grep 'use RACE_KEY' "$d/state/grants.log" 'no use receipt logged for the vanished read'
assert_grep 'no active grant for RACE_KEY' "$d/err" 'vanished-value exec falls back loudly'
assert_grep 'inject +RACE_KEY -- /bin/sh' "$d/av.log" 'fallback execs av inject with the command directly'
assert_no_value_leak "$d" "$SECRET" 'read-race case'
pass 'a failed or empty Keychain read falls back to av and consumes no use'

# --- combined uses+deadline: whichever limit comes first wins ----------------

d=$(new_case)
printf '%s' "$SECRET" > "$d/avsecrets/COMBO_USES"
printf '%s' "$SECRET" > "$d/avsecrets/COMBO_TIME"

fmg "$d" grant COMBO_USES --uses 1 --until 12h --reason 'captain: combo uses-first'
expect_code 0 "$RC" 'combined grant accepted'
fmg "$d" exec COMBO_USES -- /usr/bin/true
expect_code 0 "$RC" 'first combined exec consumes the single use'
assert_grep 'expire COMBO_USES limit=uses' "$d/state/grants.log" 'uses limit trips first'
fmg "$d" exec COMBO_USES -- /usr/bin/true
expect_code 0 "$RC" 'post-exhaustion exec completes via av'
assert_grep 'no active grant' "$d/err" 'uses-exhausted combined grant falls back'

fmg "$d" grant COMBO_TIME --uses 5 --until 12h --reason 'captain: combo deadline-first'
expect_code 0 "$RC" 'second combined grant accepted'
sed 's/^deadline_epoch=.*/deadline_epoch=100/' "$d/state/grants/COMBO_TIME" > "$d/tmpstate"
mv "$d/tmpstate" "$d/state/grants/COMBO_TIME"
fmg "$d" exec COMBO_TIME -- /usr/bin/true
expect_code 0 "$RC" 'deadline-tripped exec still completes via av'
assert_grep 'no active grant for COMBO_TIME' "$d/err" 'deadline expiry falls back loudly'
assert_grep 'expire COMBO_TIME limit=deadline' "$d/state/grants.log" 'deadline limit trips despite remaining uses'
[ "$(grant_field "$d" COMBO_TIME uses_left)" = 0 ] || fail 'expired grant normalized'
assert_no_grep 'use COMBO_TIME' "$d/state/grants.log" 'no use consumed after the deadline'
assert_present "$d/keychain/COMBO_TIME" 'expiry keeps the Keychain item'

fmg "$d" status
expect_code 0 "$RC" 'status succeeds'
assert_grep 'NOT a security control' "$d/out" 'status leads with the honest identity'
assert_grep 'ANY same-user process' "$d/out" 'status states the real exposure'
assert_grep 'COMBO_TIME' "$d/out" 'status lists the expired key'
assert_grep 'NO active grant' "$d/out" 'status shows imported-but-inactive honestly'
assert_grep 'captain: combo uses-first' "$d/out" 'status shows the recorded reason'
assert_no_value_leak "$d" "$SECRET" 'combined-limits case'
pass 'combined uses+deadline grants expire on the first limit and status stays honest'

# --- no-grant fallback consumes nothing and never captures the value ---------

d=$(new_case)
FALLBACK_VALUE='fallback-value-zz9-never-in-output'
printf '%s' "$FALLBACK_VALUE" > "$d/avsecrets/FRESH_KEY"
printf '%s' "$FALLBACK_VALUE" > "$d/expected-bytes"

# shellcheck disable=SC2016 # the child shell, not this test, expands the env var
fmg "$d" exec FRESH_KEY -- /bin/sh -c 'printf %s "$FRESH_KEY" > "$1"' _ "$d/child-out"
expect_code 0 "$RC" 'ungranted exec completes through av'
cmp -s "$d/child-out" "$d/expected-bytes" || fail 'fallback child got the value from av'
assert_grep 'no active grant for FRESH_KEY' "$d/err" 'fallback prints the loud stderr line'
assert_grep 'inject +FRESH_KEY -- /bin/sh' "$d/av.log" 'fallback is a direct av inject exec'
assert_absent "$d/state/grants/FRESH_KEY" 'fallback creates no grant state'
assert_no_grep 'use FRESH_KEY' "$d/state/grants.log" 'fallback consumes nothing'
assert_grep 'fallback ungranted=FRESH_KEY' "$d/state/grants.log" 'fallback leaves an audit line'
assert_no_value_leak "$d" "$FALLBACK_VALUE" 'fallback case'
pass 'no-grant fallback execs av directly, consumes nothing, and never captures the value'

# --- revoke keeps the key, forget removes it ---------------------------------

d=$(new_case)
printf '%s' "$SECRET" > "$d/avsecrets/ROT_KEY"
fmg "$d" grant ROT_KEY --uses 5 --reason 'captain: rotate later'
expect_code 0 "$RC" 'setup grant for revoke case'

fmg "$d" revoke ROT_KEY
expect_code 0 "$RC" 'revoke succeeds'
assert_present "$d/keychain/ROT_KEY" 'revoke keeps the Keychain item'
assert_grep 'Keychain item' "$d/out" 'revoke says the item survives'
assert_grep 'revoke ROT_KEY' "$d/state/grants.log" 'revoke logged'
fmg "$d" exec ROT_KEY -- /usr/bin/true
expect_code 0 "$RC" 'revoked exec completes via av'
assert_grep 'no active grant' "$d/err" 'revoked grant falls back'

av_before=$(av_lines "$d")
fmg "$d" grant ROT_KEY --uses 2 --reason 'captain: again'
expect_code 0 "$RC" 're-grant after revoke succeeds'
[ "$(av_lines "$d")" -eq "$av_before" ] || fail 're-grant after revoke skips av (item still stored)'
fmg "$d" exec ROT_KEY -- /usr/bin/true
expect_code 0 "$RC" 're-granted exec succeeds'
[ "$(grant_field "$d" ROT_KEY uses_left)" = 1 ] || fail 're-granted key consumes again'

fmg "$d" forget ROT_KEY
expect_code 0 "$RC" 'forget succeeds'
assert_absent "$d/keychain/ROT_KEY" 'forget wipes the Keychain item'
assert_absent "$d/state/grants/ROT_KEY" 'forget removes the grant record'
assert_grep 'forget ROT_KEY keychain=removed' "$d/state/grants.log" 'forget logged'
assert_no_value_leak "$d" "$SECRET" 'revoke/forget case'
pass 'revoke keeps the Keychain item while forget wipes it and the record'

# --- concurrent execs decrement exactly once each (spinlock proof) -----------

d=$(new_case)
printf '%s' "$SECRET" > "$d/avsecrets/CONC_KEY"
fmg "$d" grant CONC_KEY --uses 20 --reason 'captain: parallel lanes'
expect_code 0 "$RC" 'setup grant for concurrency case'

pids=
i=0
while [ "$i" -lt 4 ]; do
  PATH="$FAKEBIN:$PATH" \
    FAKE_KEYCHAIN="$d/keychain" \
    FAKE_AV_SECRETS="$d/avsecrets" \
    AV_LOG="$d/av.log" \
    FM_HOME="$d" \
    FM_GRANT_STATE_DIR="$d/state" \
    "$FM_GRANT" exec CONC_KEY -- /usr/bin/true > "$d/out.$i" 2> "$d/err.$i" &
  pids="$pids $!"
  i=$((i + 1))
done
for p in $pids; do
  wait "$p" || fail 'concurrent exec exited nonzero'
done
[ "$(grant_field "$d" CONC_KEY uses_left)" = 16 ] \
  || fail "4 concurrent execs must decrement exactly 4 (uses_left=$(grant_field "$d" CONC_KEY uses_left))"
[ "$(grep -c ' use CONC_KEY ' "$d/state/grants.log")" -eq 4 ] || fail 'exactly four use receipts logged'
pass 'concurrent execs decrement exactly once each - the mkdir spinlock holds'

# --- grant-shape warnings warn without blocking ------------------------------

d=$(new_case)
for k in PERM_KEY WIDE_KEY LONG_KEY STRIPE_LIVE_KEY; do
  printf '%s' "$SECRET" > "$d/avsecrets/$k"
done
printf '%s' 'linear-value-abc' > "$d/avsecrets/LINEAR_API_KEY"

fmg "$d" grant PERM_KEY --permanent --reason 'captain: forever'
expect_code 0 "$RC" '--permanent grant succeeds despite the warning'
assert_grep 'grant-shape warning' "$d/err" '--permanent warns'
fmg "$d" grant WIDE_KEY --uses 500 --reason 'captain: wide'
expect_code 0 "$RC" 'wide uses grant succeeds despite the warning'
assert_grep 'grant-shape warning' "$d/err" 'uses>100 warns'
fmg "$d" grant LONG_KEY --until 90d --reason 'captain: long'
expect_code 0 "$RC" 'long deadline grant succeeds despite the warning'
assert_grep 'grant-shape warning' "$d/err" 'until>30d warns'
fmg "$d" grant STRIPE_LIVE_KEY --uses 5 --reason 'captain: stripe'
expect_code 0 "$RC" 'consequence-listed grant succeeds despite the warning'
assert_grep 'grant-shape warning' "$d/err" 'consequence-listed name warns'
fmg "$d" grant LINEAR_API_KEY --uses 20 --reason 'captain: linear'
expect_code 0 "$RC" 'plain API key grant succeeds'
assert_no_grep 'grant-shape warning' "$d/err" 'a bounded plain API key never warns (no name heuristic)'

# shellcheck disable=SC2016 # the child shell, not this test, expands the env var
fmg "$d" exec PERM_KEY LINEAR_API_KEY -- /bin/sh -c 'printf "%s:%s" "$PERM_KEY" "$LINEAR_API_KEY" > "$1"' _ "$d/child-out"
expect_code 0 "$RC" 'multi-key exec succeeds'
printf '%s:%s' "$SECRET" 'linear-value-abc' > "$d/expected-bytes"
cmp -s "$d/child-out" "$d/expected-bytes" || fail 'multi-key exec injects each key correctly'
[ -z "$(grant_field "$d" PERM_KEY uses_left)" ] || fail 'permanent grant is not decremented'
[ "$(grant_field "$d" LINEAR_API_KEY uses_left)" = 19 ] || fail 'uses-bounded key decremented alongside permanent'
assert_grep 'use PERM_KEY uses_left=-' "$d/state/grants.log" 'permanent retrieval still leaves a receipt'
assert_no_value_leak "$d" "$SECRET" 'shape-warning case'
pass 'shape warnings warn without blocking, and permanent grants exec without decrement'
