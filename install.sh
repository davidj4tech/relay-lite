#!/usr/bin/env bash
#
# install.sh — relay-lite, from a Cloudflare API token to a running runner.
#
#     ./install.sh                 # interactive: asks for the token if not in env
#     CLOUDFLARE_API_TOKEN=... ./install.sh
#     ./install.sh --no-service    # everything except starting the runner
#
# The ONE manual step is the token. Create it at
#   https://dash.cloudflare.com/profile/api-tokens  ->  Create Token  ->  Custom
# with these permissions, all at Account scope:
#   Workers Scripts : Edit
#   D1              : Edit
#   Account Settings: Read
# (No zone permissions: the Worker lives on workers.dev.)
#
# From that token this script: finds the account, creates the D1 database,
# applies the schema, registers a workers.dev subdomain if the account has
# none, generates the HMAC key and the URL secret, sets both as Worker
# secrets, deploys the Worker, writes ~/.config/relay-lite/{env,relay.key},
# and starts the runner as a systemd user service. Re-running is safe: every
# step checks before it creates.
#
# Linux or WSL2. On WSL2 the runner needs systemd (wsl.conf [boot] systemd=true);
# if it is off this script turns it on and tells you to `wsl --shutdown` and
# re-run.

set -euo pipefail
HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
CONF="$HOME/.config/relay-lite"
NO_SERVICE=0
[[ "${1:-}" == "--no-service" ]] && NO_SERVICE=1

# install.conf beside this script, if present, answers the questions in
# advance so the person running it types nothing: CLOUDFLARE_API_TOKEN,
# CLOUDFLARE_ACCOUNT_ID (optional), RELAY_SITE. Copy install.conf.example.
if [[ -r "$HERE/install.conf" ]]; then set -a; . "$HERE/install.conf"; set +a; fi

# One account can hold several of these (one per machine). RELAY_SITE names
# this one; it goes into the Worker and database names so they never
# collide. Default: this machine's hostname.
RELAY_SITE="${RELAY_SITE:-$(hostname -s 2>/dev/null || hostname)}"
RELAY_SITE=$(printf '%s' "$RELAY_SITE" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-\n' '-' | sed 's/^-*//; s/-*$//' | cut -c1-30)
[[ -n "$RELAY_SITE" ]] || RELAY_SITE=site
WORKER_NAME="${RELAY_WORKER_NAME:-relay-lite-$RELAY_SITE}"
DB_NAME="${RELAY_DB_NAME:-relay-lite-$RELAY_SITE}"
API=https://api.cloudflare.com/client/v4

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
cf()   { curl -fsS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H 'Content-Type: application/json' "$@"; }

# --- 1. dependencies -------------------------------------------------------
say "Checking dependencies"
need_apt=()
for d in curl jq openssl; do command -v "$d" >/dev/null 2>&1 || need_apt+=("$d"); done
if (( ${#need_apt[@]} )); then
  note "installing: ${need_apt[*]}"
  sudo apt-get update -qq && sudo apt-get install -y -qq "${need_apt[@]}"
fi
node_ok=0
if command -v node >/dev/null 2>&1; then
  v=$(node -v | sed 's/^v//' | cut -d. -f1); (( v >= 20 )) && node_ok=1
fi
if (( ! node_ok )); then
  note "installing Node 22 (NodeSource)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs
fi
NODE_BIN=$(dirname "$(command -v node)")
note "node $(node -v), npm $(npm -v)"
( cd "$HERE/worker" && npm install --silent --no-audit --no-fund ) || die "npm install failed in lite/worker"
WRANGLER="$HERE/worker/node_modules/.bin/wrangler"
note "wrangler $("$WRANGLER" --version 2>/dev/null | tail -1)"

# --- 2. the token ----------------------------------------------------------
say "Cloudflare API token (site: $RELAY_SITE -> Worker $WORKER_NAME, database $DB_NAME)"
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -r "$CONF/env" ]]; then
  CLOUDFLARE_API_TOKEN=$(sed -n 's/^CLOUDFLARE_API_TOKEN=//p' "$CONF/env" | tail -1)
fi
if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  cat <<'EOF'
    The installer needs a Cloudflare API token. Full steps are in SETUP.md;
    the short version:
      1. Sign in at https://dash.cloudflare.com (a free account is enough).
      2. Open https://dash.cloudflare.com/profile/api-tokens
         -> Create Token -> Create Custom Token (Get started).
      3. Name it relay-lite and add three permissions, all "Account":
            Workers Scripts   Edit
            D1                Edit
            Account Settings  Read
      4. Continue to summary -> Create Token -> copy it (shown once).
EOF
  read -rsp "    Paste the token here and press Enter: " CLOUDFLARE_API_TOKEN; echo
fi
export CLOUDFLARE_API_TOKEN
cf "$API/user/tokens/verify" | jq -e '.success and .result.status == "active"' >/dev/null || die "the token did not verify"
accounts=$(cf "$API/accounts?per_page=50")
n=$(jq '.result | length' <<<"$accounts")
(( n >= 1 )) || die "the token can see no accounts; it needs Account Settings: Read"
if [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then ACCOUNT_ID="$CLOUDFLARE_ACCOUNT_ID"
elif (( n == 1 )); then ACCOUNT_ID=$(jq -r '.result[0].id' <<<"$accounts")
else
  note "The token can see several accounts:"
  jq -r '.result[] | "      \(.id)  \(.name)"' <<<"$accounts"
  read -rp "    Account id to use: " ACCOUNT_ID
fi
export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"
note "account $ACCOUNT_ID ($(jq -r --arg a "$ACCOUNT_ID" '.result[] | select(.id==$a) | .name' <<<"$accounts"))"

# --- 3. D1 -----------------------------------------------------------------
say "D1 database '$DB_NAME'"
DB_ID=$(cf "$API/accounts/$ACCOUNT_ID/d1/database?name=$DB_NAME&per_page=100" | jq -r --arg n "$DB_NAME" '.result[] | select(.name==$n) | .uuid' | head -1)
if [[ -z "$DB_ID" ]]; then
  DB_ID=$(cf -X POST "$API/accounts/$ACCOUNT_ID/d1/database" --data "{\"name\":\"$DB_NAME\"}" | jq -r '.result.uuid')
  note "created $DB_ID"
else
  note "exists: $DB_ID"
fi
[[ "$DB_ID" =~ ^[0-9a-f-]{36}$ ]] || die "could not get a database id"

# --- 4. wrangler config ----------------------------------------------------
say "Writing worker/wrangler.jsonc"
sed -e "s/__WORKER_NAME__/$WORKER_NAME/" -e "s/__ACCOUNT_ID__/$ACCOUNT_ID/" \
    -e "s/__DB_NAME__/$DB_NAME/" -e "s/__DB_ID__/$DB_ID/" \
    "$HERE/worker/wrangler.jsonc.template" > "$HERE/worker/wrangler.jsonc"
( cd "$HERE/worker" && "$WRANGLER" d1 execute "$DB_NAME" --remote --file "$HERE/schema.sql" >/dev/null ) || die "applying schema.sql failed"
# Columns added after the first release, for a database created before
# them. ALTER TABLE is not idempotent in SQLite, so look first.
cols=$( cd "$HERE/worker" && "$WRANGLER" d1 execute "$DB_NAME" --remote --json --command "PRAGMA table_info(commands);" 2>/dev/null | jq -r '.[0].results[].name' )
for col in background cancel; do
  if ! grep -qx "$col" <<<"$cols"; then
    ( cd "$HERE/worker" && "$WRANGLER" d1 execute "$DB_NAME" --remote --command "ALTER TABLE commands ADD COLUMN $col INTEGER NOT NULL DEFAULT 0;" >/dev/null ) \
      || die "adding the $col column failed"
    note "added the $col column"
  fi
done
note "schema applied"

# --- 5. secrets --------------------------------------------------------------
say "Keys"
mkdir -p "$CONF"; chmod 700 "$CONF"
if [[ ! -s "$CONF/relay.key" ]]; then
  openssl rand -hex 32 > "$CONF/relay.key"; chmod 600 "$CONF/relay.key"; note "generated relay.key"
else note "relay.key exists, keeping it"; fi
if [[ -r "$CONF/env" ]] && URL_SECRET=$(sed -n 's/^RELAY_URL_SECRET=//p' "$CONF/env" | tail -1) && [[ -n "$URL_SECRET" ]]; then
  note "URL secret exists, keeping it"
else
  URL_SECRET=$(openssl rand -hex 24); note "generated the URL secret"
fi
( cd "$HERE/worker" \
  && tr -d '[:space:]' < "$CONF/relay.key" | "$WRANGLER" secret put RELAY_HMAC_KEY >/dev/null \
  && printf '%s' "$URL_SECRET" | "$WRANGLER" secret put RELAY_URL_SECRET >/dev/null ) || die "setting Worker secrets failed"
note "Worker secrets set"

# --- 6. workers.dev subdomain, then deploy ----------------------------------
say "Deploying the Worker"
sub=$(cf "$API/accounts/$ACCOUNT_ID/workers/subdomain" | jq -r '.result.subdomain // empty')
if [[ -z "$sub" ]]; then
  want="relay-$(openssl rand -hex 3)"
  cf -X PUT "$API/accounts/$ACCOUNT_ID/workers/subdomain" --data "{\"subdomain\":\"$want\"}" >/dev/null \
    || die "the account has no workers.dev subdomain and registering '$want' failed"
  sub="$want"; note "registered workers.dev subdomain: $sub"
fi
( cd "$HERE/worker" && "$WRANGLER" deploy 2>&1 | tail -3 | sed 's/^/    /' ) || die "wrangler deploy failed"
WORKER_URL="https://$WORKER_NAME.$sub.workers.dev"

# --- 7. local config ---------------------------------------------------------
say "Writing $CONF/env"
cat > "$CONF/env" <<EOF
# relay-lite — written by install.sh $(date +%F). The token here is what the
# runner uses to read and write the queue; keep this file private.
CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN
CLOUDFLARE_ACCOUNT_ID=$ACCOUNT_ID
RELAY_SITE=$RELAY_SITE
RELAY_WORKER_NAME=$WORKER_NAME
RELAY_DB_NAME=$DB_NAME
RELAY_KEY_FILE=$CONF/relay.key
RELAY_URL_SECRET=$URL_SECRET
RELAY_WORKER_URL=$WORKER_URL
RELAY_POLL=5
RELAY_CMD_TIMEOUT=600
EOF
chmod 600 "$CONF/env"
chmod +x "$HERE/relay-lite.sh"

# --- 8. smoke test: queue a row the way the Worker does, run it once ---------
say "Smoke test"
# A fresh deploy takes a few seconds to reach every edge; the first probe
# after it answered 404 on 2026-09-17. Retry for up to a minute.
resp=""
for i in $(seq 1 12); do
  resp=$(curl -fsS -X POST "$WORKER_URL/$URL_SECRET/mcp" -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"echo relay-lite-ok","wait":0}}}' 2>/dev/null) && break
  note "waiting for the deploy to propagate ($((i*5))s)"; sleep 5
done
[[ -n "$resp" ]] || die "the Worker did not answer at $WORKER_URL/<secret>/mcp after a minute"
rid=$(jq -r '.result.content[0].text' <<<"$resp" | grep -oE '^#[0-9]+' | tr -d '#')
[[ -n "$rid" ]] || die "unexpected Worker reply: $resp"
"$HERE/relay-lite.sh" --once 2>&1 | sed 's/^/    /'
# get_result with a wait: if a service is already running it may have taken
# the row before the one-shot poll above, and still be on it.
got=$(curl -fsS -X POST "$WORKER_URL/$URL_SECRET/mcp" -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_result\",\"arguments\":{\"id\":$rid,\"wait\":60}}}" \
  | jq -r '.result.content[0].text')
grep -q 'relay-lite-ok' <<<"$got" || die "smoke test failed; the runner did not produce the result: $got"
note "queued #$rid, ran it, read the output back: OK"

# --- 9. the service ----------------------------------------------------------
if (( NO_SERVICE )); then
  say "Not starting the service (--no-service). Run it with: $HERE/relay-lite.sh"
else
  say "Starting the runner as a systemd user service"
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
      note "systemd is not running in this WSL distro. Enabling it in /etc/wsl.conf."
      printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
      note "From PowerShell run:  wsl --shutdown   then open the distro again and re-run ./install.sh"
      note "Until then, run the runner by hand: $HERE/relay-lite.sh"
    else
      note "systemd user session not available; run the runner by hand: $HERE/relay-lite.sh"
    fi
  else
    mkdir -p "$HOME/.config/systemd/user"
    sed -e "s|__LITE_DIR__|$HERE|g" -e "s|__NODE_BIN__|$NODE_BIN|g" "$HERE/relay-lite.service" \
      > "$HOME/.config/systemd/user/relay-lite.service"
    systemctl --user daemon-reload
    systemctl --user enable --now relay-lite >/dev/null
    sudo loginctl enable-linger "$USER" 2>/dev/null || true
    sleep 2
    note "relay-lite.service: $(systemctl --user is-active relay-lite)"
  fi
fi

say "Done"
cat <<EOF
    Connector URL (treat it as a password; it is the only credential):

        $WORKER_URL/$URL_SECRET/mcp

    In Claude: Settings -> Connectors -> Add custom connector, paste that URL,
    no authentication. Then ask it to run a command.

    Runner log:  journalctl --user -u relay-lite -f
    Config:      $CONF/env   (token, secret, URL)   $CONF/relay.key
    Re-run this script any time; it keeps existing keys and ids.
EOF
