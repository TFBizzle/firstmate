#!/usr/bin/env bash
# fm-grant.sh - captain-authorized grant vault: a bounded convenience window of
# promptless secret access for firstmate's own fleet, with receipts.
#
# HONESTY FIRST: this is NOT a security control. Once `grant` imports a secret
# into the macOS Keychain (service firstmate-grant), ANY same-user process can
# read it silently with `security find-generic-password -w` until `forget`
# removes the item. Grant counts and expiry are cooperative bookkeeping and an
# audit trail bounding firstmate's own polite usage - they are not an OS
# boundary. `forget` is the only real revocation; expiry and `revoke` close the
# bookkeeping window but leave the item readable.
#
# NEVER `av bless` this script. The single remaining human checkpoint is the
# one av approval on first import; blessing fm-grant.sh would delete that
# checkpoint and make every future import promptless and unbounded.
#
# The public surface never prints a secret: `exec` injects resolved values into
# the child command's environment only, because a value printed to stdout lands
# in agent transcripts, panes, and reports. There is deliberately no public
# `get`. Without an active grant, `exec` execs `av inject +KEY... -- cmd`
# directly - the value never transits this script on that path - after one loud
# stderr line, so a headless lane does not wedge silently on the hidden av
# dialog. Import runs `av inject +KEY -- fm-grant.sh _store KEY`: the value
# travels env -> child -> `security` with no `sh -c`, no pipe, and no plaintext
# on any file descriptor, and the av dialog legibly names `_store KEY`.
#
# State: per-secret shell-parseable files under <state>/grants/<KEY> plus one
# append-only <state>/grants.log, where <state> is
# ${FM_GRANT_STATE_DIR:-${FM_STATE_OVERRIDE:-$FM_HOME/state}} so secondmate
# homes never share grants. Dir 0700, files 0600, umask 077, atomic tmp+mv
# writes, and an mkdir spinlock around every read-decrement-write because
# parallel lanes race the counter. Grant bounds combine and whichever limit
# comes first wins; a "use" is one key retrieval; expiry is applied lazily on
# every exec and status. Trailing newlines are stripped on import and
# retrieval (fine for tokens). macOS-only: needs `security` and `av`.
#
# Usage:
#   fm-grant.sh grant KEY (--uses N | --until <N><s|m|h|d> | --permanent)... \
#     --reason "<captain's literal words>"
#   fm-grant.sh exec KEY [KEY...] -- <cmd> [args...]
#   fm-grant.sh status
#   fm-grant.sh revoke KEY|--all     close the grant, KEEP the Keychain item
#   fm-grant.sh forget KEY|--all     wipe the Keychain item and the record
#
# `grant` requires --reason (the captain's words, logged and shown in status)
# and at least one explicit bound. It warns - never blocks - on risky grant
# shapes: --permanent, uses over 100, until over 30 days, and names on the
# small consequence list (PAYMENT|TEBEX|STRIPE|PROD|DEPLOY|SIGNING). The
# hidden `_store` subcommand exists only as the av inject target above;
# agents never call it directly.
{ set +x; } 2>/dev/null # a secret must never reach an inherited xtrace
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-grant.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
GRANT_STATE="${FM_GRANT_STATE_DIR:-$STATE}"
GRANTS_DIR="$GRANT_STATE/grants"
GRANT_LOG="$GRANT_STATE/grants.log"
SERVICE=firstmate-grant

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

fail() {
  printf 'fm-grant: %s\n' "$*" >&2
  exit 1
}

# Spelled-out classes: a [A-Z] case range is locale-collation-dependent and can
# match lowercase, so the injection-critical name check never uses ranges.
readonly KEY_ALPHA=ABCDEFGHIJKLMNOPQRSTUVWXYZ
validate_key() {
  case "$1" in
    ["$KEY_ALPHA"]*) : ;;
    *) fail "invalid secret name '$1' (must match ^[A-Z][A-Z0-9_]*\$)" ;;
  esac
  case "$1" in
    *[!"$KEY_ALPHA"0123456789_]*) fail "invalid secret name '$1' (must match ^[A-Z][A-Z0-9_]*\$)" ;;
  esac
}

is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

ensure_grant_dirs() {
  mkdir -p "$GRANTS_DIR" || fail "cannot create $GRANTS_DIR"
  chmod 700 "$GRANTS_DIR" 2>/dev/null || :
}

log_event() {
  mkdir -p "$GRANT_STATE" || fail "cannot create $GRANT_STATE"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$GRANT_LOG" \
    || fail "cannot append to $GRANT_LOG"
}

# mkdir spinlock around every read-decrement-write: macOS has no flock and
# firstmate's parallel lanes race the counter otherwise. Bounded retries with a
# stale-by-mtime steal so a killed holder cannot wedge the key forever.
lock_key() {
  local dir="$GRANTS_DIR/.$1.lock" tries=0 mtime now
  ensure_grant_dirs
  while ! mkdir "$dir" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || fail "timed out waiting for the $1 grant lock ($dir)"
    mtime=$(stat -c %Y "$dir" 2>/dev/null || stat -f %m "$dir" 2>/dev/null) || mtime=
    case "$mtime" in '' | *[!0-9]*) mtime= ;; esac
    now=$(date +%s)
    if [ -n "$mtime" ] && [ $((now - mtime)) -gt 30 ]; then
      rmdir "$dir" 2>/dev/null || :
      continue
    fi
    sleep 0.05
  done
}

unlock_key() {
  rmdir "$GRANTS_DIR/.$1.lock" 2>/dev/null || :
}

grant_field() { # <KEY> <field> - first value, empty when absent
  sed -n "s/^$2=//p" "$GRANTS_DIR/$1" 2>/dev/null | sed -n 1p
}

# Atomic install of the full six-field grant record (house tmp+mv idiom).
write_grant_file() { # <KEY> <uses> <deadline> <permanent> <created> <reason>
  local key=$1 uses=$2 deadline=$3 permanent=$4 created=$5 reason=$6 tmp
  ensure_grant_dirs
  tmp=$(mktemp "$GRANTS_DIR/.$key.tmp.XXXXXX") || fail "cannot stage grant state for $key"
  {
    printf 'uses_left=%s\n' "$uses"
    printf 'deadline_epoch=%s\n' "$deadline"
    printf 'permanent=%s\n' "$permanent"
    printf 'created_at=%s\n' "$created"
    printf 'reason=%s\n' "$reason"
    printf 'imported_from=av\n'
  } > "$tmp" || { rm -f "$tmp"; fail "cannot write grant state for $key"; }
  chmod 0600 "$tmp" 2>/dev/null || :
  mv -f "$tmp" "$GRANTS_DIR/$key" || { rm -f "$tmp"; fail "cannot install grant state for $key"; }
}

grant_active() { # <KEY> - 0 while the bookkeeping window is open
  local uses deadline permanent now
  [ -f "$GRANTS_DIR/$1" ] || return 1
  uses=$(grant_field "$1" uses_left)
  deadline=$(grant_field "$1" deadline_epoch)
  permanent=$(grant_field "$1" permanent)
  if [ -n "$uses" ]; then
    is_uint "$uses" || return 1
    [ "$uses" -gt 0 ] || return 1
  fi
  if [ -n "$deadline" ]; then
    is_uint "$deadline" || return 1
    now=$(date +%s)
    [ "$now" -le "$deadline" ] || return 1
  fi
  if [ "$permanent" = 1 ]; then
    return 0
  fi
  [ -n "$uses" ] || [ -n "$deadline" ] || return 1
  return 0
}

# Lazy expiry (caller holds the key lock): normalize a tripped grant to the
# terminal closed form exactly once, logging which limit came first. The
# Keychain item deliberately stays - only `forget` removes it.
expire_norm() { # <KEY>
  local uses deadline created reason limit
  [ -f "$GRANTS_DIR/$1" ] || return 0
  if grant_active "$1"; then
    return 0
  fi
  uses=$(grant_field "$1" uses_left)
  deadline=$(grant_field "$1" deadline_epoch)
  if [ "$uses" = 0 ] && [ -z "$deadline" ]; then
    return 0 # already in the terminal closed form
  fi
  limit=deadline
  if [ -n "$uses" ] && is_uint "$uses" && [ "$uses" -le 0 ]; then
    limit=uses
  fi
  created=$(grant_field "$1" created_at)
  reason=$(grant_field "$1" reason)
  write_grant_file "$1" 0 '' 0 "$created" "$reason"
  log_event "expire $1 limit=$limit"
}

# One retrieval consumes one use (caller holds the key lock; grant is active).
# Time-only and permanent grants are not decremented but still leave a receipt.
consume_use() { # <KEY>
  local uses deadline permanent created reason
  uses=$(grant_field "$1" uses_left)
  if [ -z "$uses" ]; then
    log_event "use $1 uses_left=-"
    return 0
  fi
  uses=$((uses - 1))
  created=$(grant_field "$1" created_at)
  reason=$(grant_field "$1" reason)
  if [ "$uses" -le 0 ]; then
    write_grant_file "$1" 0 '' 0 "$created" "$reason"
    log_event "use $1 uses_left=0"
    log_event "expire $1 limit=uses"
    return 0
  fi
  deadline=$(grant_field "$1" deadline_epoch)
  permanent=$(grant_field "$1" permanent)
  write_grant_file "$1" "$uses" "$deadline" "$permanent" "$created" "$reason"
  log_event "use $1 uses_left=$uses"
}

keychain_has() {
  security find-generic-password -s "$SERVICE" -a "$1" >/dev/null 2>&1
}

keychain_read() {
  security find-generic-password -w -s "$SERVICE" -a "$1" 2>/dev/null
}

parse_duration() { # <N><s|m|h|d> -> seconds on stdout
  local n unit
  case "$1" in
    '' | [!0-9]* | *[!0-9smhd]*) return 1 ;;
  esac
  unit=${1##*[0-9]}
  n=${1%"$unit"}
  is_uint "$n" || return 1
  [ "$n" -ge 1 ] || return 1
  case "$unit" in
    s) printf '%s\n' "$n" ;;
    m) printf '%s\n' $((n * 60)) ;;
    h) printf '%s\n' $((n * 3600)) ;;
    d) printf '%s\n' $((n * 86400)) ;;
    *) return 1 ;;
  esac
}

fmt_epoch() { # best-effort human timestamp for status output
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf 'epoch %s\n' "$1"
}

describe_bounds() { # <uses> <deadline> <permanent>
  local out=''
  if [ "$3" = 1 ]; then
    out='permanent'
  fi
  if [ -n "$1" ]; then
    out="${out:+$out, }uses left: $1"
  fi
  if [ -n "$2" ]; then
    out="${out:+$out, }until $(fmt_epoch "$2")"
  fi
  printf '%s\n' "${out:-closed}"
}

warn_shape() { # <KEY> <why> - the risk axis is the grant SHAPE, never a name heuristic
  printf 'fm-grant: grant-shape warning: %s - %s.\n' "$1" "$2" >&2
}

# One av approval permanently moves KEY under promptless custody; say so
# loudly BEFORE the hidden dialog fires so nobody approves it half-informed.
import_key() { # <KEY>
  printf 'fm-grant: importing %s: after this ONE av approval, %s moves permanently under weaker promptless custody - ANY same-user process can read it silently until "fm-grant.sh forget %s".\n' "$1" "$1" "$1" >&2
  printf 'fm-grant: an av approval dialog may now be waiting; it reads "fm-grant.sh _store %s".\n' "$1" >&2
  av inject "+$1" -- "$SELF" _store "$1" \
    || fail "import of $1 was not approved or av failed - no grant recorded"
  keychain_has "$1" || fail "import of $1 did not land in the Keychain - no grant recorded"
  log_event "import $1 via=av"
}

cmd_grant() {
  local key uses='' dur='' permanent=0 reason='' deadline='' seconds=0 created
  [ $# -ge 1 ] || fail 'usage: fm-grant.sh grant KEY [--uses N] [--until <N><s|m|h|d>] [--permanent] --reason "..."'
  key=$1
  shift
  validate_key "$key"
  while [ $# -gt 0 ]; do
    case "$1" in
      --uses)
        [ $# -ge 2 ] || fail '--uses needs a count'
        uses=$2
        shift 2
        ;;
      --until)
        [ $# -ge 2 ] || fail '--until needs a duration like 12h or 7d'
        dur=$2
        shift 2
        ;;
      --permanent)
        permanent=1
        shift
        ;;
      --reason)
        [ $# -ge 2 ] || fail "--reason needs the captain's words"
        reason=$2
        shift 2
        ;;
      *) fail "unknown grant option: $1" ;;
    esac
  done
  [ -n "$reason" ] || fail "--reason is required: quote the captain's explicit instruction"
  case "$reason" in
    *$'\n'* | *$'\r'*) fail '--reason must be one line' ;;
  esac
  if [ -n "$uses" ]; then
    if ! is_uint "$uses" || [ "$uses" -lt 1 ]; then
      fail '--uses must be a positive integer'
    fi
  fi
  if [ -n "$dur" ]; then
    seconds=$(parse_duration "$dur") || fail '--until must be <N><s|m|h|d>, e.g. 12h or 7d'
    deadline=$(($(date +%s) + seconds))
  fi
  if [ -z "$uses" ] && [ -z "$dur" ] && [ "$permanent" != 1 ]; then
    fail 'state an explicit bound: --uses N, --until <dur>, or --permanent'
  fi
  if [ "$permanent" = 1 ]; then
    warn_shape "$key" '--permanent never expires; only revoke or forget ends it'
  fi
  if [ -n "$uses" ] && [ "$uses" -gt 100 ]; then
    warn_shape "$key" "--uses $uses is an unusually wide window"
  fi
  if [ -n "$dur" ] && [ "$seconds" -gt $((30 * 86400)) ]; then
    warn_shape "$key" "--until $dur is longer than 30 days"
  fi
  case "$key" in
    *PAYMENT* | *TEBEX* | *STRIPE* | *PROD* | *DEPLOY* | *SIGNING*)
      warn_shape "$key" 'this name suggests money, production, or release authority'
      ;;
  esac
  if ! keychain_has "$key"; then
    import_key "$key"
  fi
  created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  lock_key "$key"
  write_grant_file "$key" "$uses" "$deadline" "$permanent" "$created" "$reason"
  unlock_key "$key"
  log_event "grant $key uses=${uses:--} until=${dur:--} permanent=$permanent reason=$reason"
  printf 'fm-grant: granted %s (%s).\n' "$key" "$(describe_bounds "$uses" "$deadline" "$permanent")"
  printf 'fm-grant: bookkeeping only - %s stays silently readable by ANY same-user process until "fm-grant.sh forget %s".\n' "$key" "$key"
}

# Hidden import plumbing target for `av inject +KEY -- fm-grant.sh _store KEY`:
# the value arrives in this process's own environment and goes straight to
# `security`, so it never touches stdout, a pipe, or a shell command line here.
cmd_store() {
  [ $# -eq 1 ] || fail '_store expects exactly one KEY'
  validate_key "$1"
  local name=$1 value
  value=${!name-}
  [ -n "$value" ] || fail "_store expected $name in the environment (it arrives via av inject)"
  value=${value%$'\n'} # tokens never need a trailing newline; documented
  security add-generic-password -U -s "$SERVICE" -a "$name" -w "$value" >/dev/null 2>&1 \
    || fail "Keychain write for $name failed"
}

grant_usable() { # <KEY> - active window AND a readable Keychain item
  [ -f "$GRANTS_DIR/$1" ] || return 1
  keychain_has "$1" || return 1
  local usable=1
  lock_key "$1"
  expire_norm "$1"
  if grant_active "$1"; then
    usable=0
  fi
  unlock_key "$1"
  return "$usable"
}

# No-grant path: one loud line so a headless lane does not wedge silently, then
# exec av directly - the value never transits fm-grant here, and nothing is
# consumed from any grant.
exec_av_fallback() { # <ungranted-list> <KEY>... -- <cmd>...
  local ungranted=$1 avargs=()
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        break
        ;;
      *)
        avargs+=("+$1")
        shift
        ;;
    esac
  done
  printf 'fm-grant: no active grant for%s - handing to av; a macOS av approval dialog may now be waiting for a click.\n' "$ungranted" >&2
  log_event "fallback ungranted=${ungranted# }"
  exec av inject ${avargs[@]+"${avargs[@]}"} -- "$@"
}

cmd_exec() {
  local keys=() k ungranted='' v pairs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        break
        ;;
      *)
        keys+=("$1")
        shift
        ;;
    esac
  done
  [ "${#keys[@]}" -ge 1 ] || fail 'usage: fm-grant.sh exec KEY [KEY...] -- <cmd> [args...]'
  [ $# -ge 1 ] || fail 'missing command after --'
  for k in "${keys[@]}"; do
    validate_key "$k"
  done
  for k in "${keys[@]}"; do
    if ! grant_usable "$k"; then
      ungranted="$ungranted $k"
    fi
  done
  if [ -n "$ungranted" ]; then
    exec_av_fallback "$ungranted" "${keys[@]}" -- "$@"
  fi
  for k in "${keys[@]}"; do
    lock_key "$k"
    expire_norm "$k"
    if ! grant_active "$k"; then
      # Raced to exhaustion since the check above. Earlier keys already left a
      # use receipt each - acceptable for cooperative bookkeeping, and visible
      # in the log next to this fallback line.
      unlock_key "$k"
      exec_av_fallback " $k" "${keys[@]}" -- "$@"
    fi
    # Read the secret BEFORE consuming a use: if the value is gone (a "forget"
    # raced this window) a failed or empty read must not burn a use. Same-key
    # lock still held, so no other exec can consume between the read and the
    # consume here.
    if ! v=$(keychain_read "$k") || [ -z "$v" ]; then
      unlock_key "$k"
      exec_av_fallback " $k" "${keys[@]}" -- "$@"
    fi
    consume_use "$k"
    unlock_key "$k"
    pairs+=("$k=$v")
  done
  # env(1) carries the values straight into the child's environment; they are
  # never printed, logged, or exported into an intermediate shell.
  exec env ${pairs[@]+"${pairs[@]}"} "$@"
}

cmd_status() {
  [ $# -eq 0 ] || fail 'status takes no arguments'
  printf 'fm-grant status - a convenience window with receipts, NOT a security control.\n'
  printf 'Every imported key below is silently readable by ANY same-user process until "fm-grant.sh forget KEY"; grant limits bound firstmate'\''s own bookkeeping, not the OS.\n'
  local f key uses deadline permanent created reason shown=0
  if [ -d "$GRANTS_DIR" ]; then
    for f in "$GRANTS_DIR"/*; do
      [ -f "$f" ] || continue
      key=$(basename "$f")
      lock_key "$key"
      expire_norm "$key"
      uses=$(grant_field "$key" uses_left)
      deadline=$(grant_field "$key" deadline_epoch)
      permanent=$(grant_field "$key" permanent)
      created=$(grant_field "$key" created_at)
      reason=$(grant_field "$key" reason)
      if grant_active "$key"; then
        printf '%s: ACTIVE (%s)\n' "$key" "$(describe_bounds "$uses" "$deadline" "$permanent")"
      else
        printf '%s: imported, NO active grant - still promptless-readable; forget removes it\n' "$key"
      fi
      unlock_key "$key"
      printf '  reason: %s (granted %s)\n' "${reason:-?}" "${created:-?}"
      shown=1
    done
  fi
  if [ "$shown" = 0 ]; then
    printf 'No keys imported.\n'
  fi
  if [ -f "$GRANT_LOG" ]; then
    printf 'Audit log: %s\n' "$GRANT_LOG"
  fi
  return 0
}

TARGETS=()
resolve_targets() { # <subcommand> <KEY|--all>
  local sub=$1 f
  shift
  TARGETS=()
  if [ "${1-}" = --all ]; then
    [ $# -eq 1 ] || fail "$sub --all takes no other arguments"
    if [ -d "$GRANTS_DIR" ]; then
      for f in "$GRANTS_DIR"/*; do
        [ -f "$f" ] || continue
        TARGETS+=("$(basename "$f")")
      done
    fi
    [ "${#TARGETS[@]}" -ge 1 ] || fail "nothing imported - no keys to $sub"
    return 0
  fi
  [ $# -eq 1 ] || fail "usage: fm-grant.sh $sub KEY|--all"
  validate_key "$1"
  TARGETS=("$1")
}

cmd_revoke() {
  resolve_targets revoke "$@"
  local k created reason
  for k in "${TARGETS[@]}"; do
    if [ ! -f "$GRANTS_DIR/$k" ]; then
      printf 'fm-grant: no grant record for %s.\n' "$k"
      continue
    fi
    lock_key "$k"
    created=$(grant_field "$k" created_at)
    reason=$(grant_field "$k" reason)
    write_grant_file "$k" 0 '' 0 "$created" "$reason"
    unlock_key "$k"
    log_event "revoke $k"
    printf 'fm-grant: revoked %s - the window is closed, but the Keychain item REMAINS silently readable; "fm-grant.sh forget %s" removes it.\n' "$k" "$k"
  done
}

cmd_forget() {
  resolve_targets forget "$@"
  local k note
  for k in "${TARGETS[@]}"; do
    if security delete-generic-password -s "$SERVICE" -a "$k" >/dev/null 2>&1; then
      note=removed
    else
      note=absent
    fi
    lock_key "$k"
    rm -f "$GRANTS_DIR/$k"
    unlock_key "$k"
    log_event "forget $k keychain=$note"
    printf 'fm-grant: forgot %s (Keychain item %s) - promptless access ended.\n' "$k" "$note"
  done
}

SUB=${1-}
if [ $# -gt 0 ]; then
  shift
fi
case "$SUB" in
  grant) cmd_grant "$@" ;;
  exec) cmd_exec "$@" ;;
  status) cmd_status "$@" ;;
  revoke) cmd_revoke "$@" ;;
  forget) cmd_forget "$@" ;;
  _store) cmd_store "$@" ;;
  -h | --help | help)
    usage
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *) fail "unknown subcommand '$SUB' (there is deliberately no public get - values are never printed)" ;;
esac
