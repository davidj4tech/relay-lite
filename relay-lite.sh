#!/usr/bin/env bash
#
# relay-lite.sh — poll the queue, run what is signed, write the result back.
#
# ############################################################################
# ##  THIS SCRIPT EXECUTES SHELL COMMANDS READ FROM A DATABASE, as you.     ##
# ##  Whoever holds the Worker URL can run anything here. The HMAC check   ##
# ##  below is what stops a row that merely got INTO the database from     ##
# ##  running: only a row signed with relay.key is executed.               ##
# ############################################################################
#
#     relay-lite.sh            # poll forever (the service form)
#     relay-lite.sh --once     # one poll, for testing
#
# Config: ~/.config/relay-lite/env (written by install.sh):
#     CLOUDFLARE_API_TOKEN   token wrangler uses to read and write D1
#     RELAY_DB_NAME          D1 database (default relay-lite)
#     RELAY_KEY_FILE         hex key shared with the Worker (default relay.key beside env)
#     RELAY_POLL             seconds between polls (default 5)
#     RELAY_CMD_TIMEOUT      seconds a command may run (default 600)
#     RELAY_MAX_OUTPUT       bytes of output kept (default 60000)
#
# This is github.com/davidj4tech/tmux-relay's d1-runner with everything that is not "run a command
# and write the result" removed: no kinds, no panes, no Claude, no mailbox.
# The signature it checks is the same v1 scheme, so the two can share a key
# if you ever want them to.

set -uo pipefail

CONF_DIR="${RELAY_LITE_CONF:-$HOME/.config/relay-lite}"
if [[ -r "$CONF_DIR/env" ]]; then set -a; . "$CONF_DIR/env"; set +a; fi
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
WRANGLER_CFG="${RELAY_WRANGLER_CONFIG:-$HERE/worker/wrangler.jsonc}"
DB="${RELAY_DB_NAME:-relay-lite}"
KEY_FILE="${RELAY_KEY_FILE:-$CONF_DIR/relay.key}"
POLL="${RELAY_POLL:-5}"
CMD_TIMEOUT="${RELAY_CMD_TIMEOUT:-600}"
MAX_OUTPUT="${RELAY_MAX_OUTPUT:-60000}"
SEEN="${RELAY_NONCE_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/relay-lite/nonces}"

log() { printf '%s relay-lite: %s\n' "$(date '+%F %T')" "$*" >&2; }

for dep in jq openssl timeout; do
  command -v "$dep" >/dev/null 2>&1 || { log "missing dependency: $dep"; exit 1; }
done
WRANGLER=$(command -v wrangler || true)
[[ -n "$WRANGLER" && -x "$HERE/worker/node_modules/.bin/wrangler" ]] && WRANGLER="$HERE/worker/node_modules/.bin/wrangler"
[[ -n "$WRANGLER" ]] || WRANGLER="$HERE/worker/node_modules/.bin/wrangler"
[[ -x "$WRANGLER" ]] || { log "wrangler not found; run install.sh"; exit 1; }
[[ -r "$WRANGLER_CFG" ]] || { log "no wrangler config at $WRANGLER_CFG; run install.sh"; exit 1; }
[[ -r "$KEY_FILE" ]] || { log "no key at $KEY_FILE; run install.sh"; exit 1; }
KEY=$(tr -d '[:space:]' < "$KEY_FILE")
[[ "$KEY" =~ ^[0-9a-fA-F]{32,}$ ]] || { log "key in $KEY_FILE is not a hex string"; exit 1; }
mkdir -p "$(dirname "$SEEN")"

# --- D1 ----------------------------------------------------------------------
d1() {  # $1 = sql -> results array on stdout, or non-zero
  local raw
  raw=$("$WRANGLER" --config "$WRANGLER_CFG" d1 execute "$DB" --remote --json --command "$1" 2>&1) || {
    log "d1 failed: $(printf '%s' "$raw" | grep -v '^\s*$' | tail -1)"; return 1; }
  printf '%s' "$raw" | jq -ce 'if type=="array" then .[0].results // [] else error("bad envelope") end' 2>/dev/null || {
    log "unparseable d1 response: $(printf '%s' "$raw" | head -1)"; return 1; }
}
sql_lit() { printf '%s' "$1" | tr -d '\000' | sed "s/'/''/g"; }

# --- signing: identical to relay-sign.sh relay_hmac / relay_ct_equal ---------
hmac() { printf '%s\n%s' "$1" "$2" | openssl dgst -sha256 -mac HMAC -macopt "key:$KEY" -r 2>/dev/null | cut -d' ' -f1; }
ct_equal() {
  local a="$1" b="$2" i d=0
  (( ${#a} == ${#b} )) || return 1
  for (( i = 0; i < ${#a}; i++ )); do d=$(( d | ( $(printf '%d' "'${a:i:1}") ^ $(printf '%d' "'${b:i:1}") ) )); done
  (( d == 0 ))
}

write_result() {  # $1 = id, $2 = status, $3 = exit code, $4 = output
  d1 "UPDATE commands SET status = '$2', exit_code = $3, output = '$(sql_lit "$4")', updated_at = datetime('now') WHERE id = $1;" >/dev/null
}

run_one() {  # $1 = id, $2 = command, $3 = sig, $4 = nonce
  local id="$1" command="$2" sig="$3" nonce="$4" expected claimed out rc

  # Nonce seen before = a replayed row (someone re-inserted a signed row).
  if grep -qxF -- "$nonce" "$SEEN" 2>/dev/null; then
    log "#$id: nonce already used — rejecting as a replay"
    write_result "$id" rejected -1 "relay-lite: replayed nonce"; return
  fi
  expected=$(hmac "$nonce" "$command")
  if ! ct_equal "$expected" "$sig"; then
    log "#$id: BAD SIGNATURE — not executing"
    write_result "$id" rejected -1 "relay-lite: signature did not verify"; return
  fi
  # Claim it. `AND status = 'pending'` means only one runner can win.
  claimed=$("$WRANGLER" --config "$WRANGLER_CFG" d1 execute "$DB" --remote --json \
              --command "UPDATE commands SET status = 'running', updated_at = datetime('now') WHERE id = $id AND status = 'pending';" 2>/dev/null \
            | jq -r '.[0].meta.changes // 0' 2>/dev/null)
  [[ "$claimed" == 1 ]] || { log "#$id: claimed by someone else"; return; }
  printf '%s\n' "$nonce" >> "$SEEN"; tail -n 5000 "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"

  log "#$id: running: ${command:0:80}"
  out=$(timeout --kill-after=10 "$CMD_TIMEOUT" bash -lc "$command" 2>&1 </dev/null | head -c "$MAX_OUTPUT"; exit "${PIPESTATUS[0]}")
  rc=$?
  if (( rc == 124 || rc == 137 )); then
    write_result "$id" timeout "$rc" "$out
relay-lite: killed after ${CMD_TIMEOUT}s"
    log "#$id: timed out"
  else
    write_result "$id" done "$rc" "$out"
    log "#$id: exit $rc, ${#out} bytes"
  fi
}

poll() {
  local rows
  rows=$(d1 "SELECT id, command, sig, nonce FROM commands WHERE status = 'pending' ORDER BY id LIMIT 5;") || return 1
  local n; n=$(printf '%s' "$rows" | jq 'length')
  (( n > 0 )) || return 0
  local i
  for (( i = 0; i < n; i++ )); do
    run_one "$(jq -r ".[$i].id" <<<"$rows")" "$(jq -r ".[$i].command" <<<"$rows")" \
            "$(jq -r ".[$i].sig" <<<"$rows")" "$(jq -r ".[$i].nonce" <<<"$rows")"
  done
}

if [[ "${1:-}" == "--once" ]]; then poll; exit $?; fi
log "polling '$DB' every ${POLL}s; commands run as $(id -un) with a ${CMD_TIMEOUT}s limit"
while :; do poll; sleep "$POLL"; done
