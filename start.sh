#!/usr/bin/env bash
#
# Conduktor Gateway Community Edition quickstart bootstrapper.
#
#
set -euo pipefail

# Clean up the temp logs on exit (including Ctrl+C); harmless if never created.
trap 'rm -f "${UP_LOG:-}" "${PULL_LOG:-}" "${PULL_LOG:-}.code" 2>/dev/null || true' EXIT

REPO_URL="https://github.com/conduktor/gateway-community-quickstart.git"
REPO_DIR="gateway-community-quickstart"
GATEWAY_CONTAINER="conduktor-gateway"

# --- self-serve license config ----------------------------------------------
# When LICENSE_API_URL is set, the script tries to fetch a license automatically
# (email -> license). When it's empty OR the endpoint is unreachable (offline / blocked
# network / air-gap), the script falls back to the manual "request on the website and
# paste" flow -- today's behavior. This is why the script is safe to ship BEFORE the
# endpoint exists: with LICENSE_API_URL unset, it behaves exactly as it does today.
LICENSE_API_URL="${LICENSE_API_URL:-}"
LICENSE_FORM_URL="${LICENSE_FORM_URL:-https://conduktor.io/gateway/community-edition}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"     # seconds to wait when probing the endpoint
POST_TIMEOUT="${POST_TIMEOUT:-15}"      # seconds to wait for the license response

# --- pretty output -----------------------------------------------------------
if [ -t 1 ]; then
  IS_TTY=1
  BOLD='\033[1m'; GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; RESET='\033[0m'
else
  IS_TTY=
  BOLD=''; GREEN=''; RED=''; DIM=''; RESET=''
fi
step() { printf "${BOLD}▸ %s${RESET}\n" "$1"; }
ok()   { printf "${GREEN}  ✓ %s${RESET}\n" "$1"; }
info() { printf "${DIM}  %s${RESET}\n" "$1"; }
die()  { printf "${RED}  ✗ %s${RESET}\n" "$1" >&2; exit 1; }

BAR_WIDTH=28
draw_bar() { # $1 = score, $2 = max, $3 = label
  local score=$1 max=$2 label=$3 filled i pct
  filled=$(( score * BAR_WIDTH / max ))
  pct=$(( score * 100 / max ))
  printf "\r  ["
  for (( i = 0; i < BAR_WIDTH; i++ )); do
    if [ "$i" -lt "$filled" ]; then printf "█"; else printf "░"; fi
  done
  printf "] %3d%%  %-20s\033[K" "$pct" "$label"
}

# Decode a base64url segment (JWT-style: '-_' alphabet, no padding) to stdout.
b64url_decode() {
  local data="${1//-/+}"; data="${data//_//}"
  case $(( ${#data} % 4 )) in 2) data="${data}==";; 3) data="${data}=";; esac
  printf '%s' "$data" | base64 -d 2>/dev/null
}

# Cheap, offline sanity check that a string is a plausible, unexpired license JWT.
# This does NOT verify the signature — only the Gateway can do that. It just
# rejects obvious garbage up front instead of waiting for the healthcheck to fail.
validate_license() {
  local key="$1" payload exp now
  # A JWT is three non-empty base64url segments separated by dots.
  if ! printf '%s' "$key" | grep -Eq '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
    die "That doesn't look like a valid license key (expected a JWT). Request a free one at https://conduktor.io/gateway/community-edition"
  fi
  # Best-effort expiry check: decode the payload (2nd segment) and read 'exp'.
  payload="$(b64url_decode "$(printf '%s' "$key" | cut -d. -f2)")"
  exp="$(printf '%s' "$payload" | grep -oE '"exp"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
  if [ -n "$exp" ]; then
    now="$(date +%s)"
    [ "$exp" -gt "$now" ] || die "This license key has expired. Request a fresh one at https://conduktor.io/gateway/community-edition"
  fi
}

# --- self-serve provisioning helpers ----------------------------------------

# True (0) if the string is shaped like a JWT (three base64url segments).
license_is_jwt() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; }

# True (0) if the JWT carries an 'exp' claim that is already in the past.
license_expired() {
  local exp payload
  payload="$(b64url_decode "$(printf '%s' "$1" | cut -d. -f2)")"
  exp="$(printf '%s' "$payload" | grep -oE '"exp"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
  [ -n "$exp" ] && [ "$exp" -le "$(date +%s)" ]
}

# Pull a top-level string field out of a small JSON blob (no jq dependency).
json_str() { printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' || true; }

# True (0) if LICENSE_API_URL answers at all (any HTTP status). A connection failure or
# timeout yields "000" -> treated as unreachable (offline / blocked / air-gapped).
endpoint_reachable() {
  [ -n "$LICENSE_API_URL" ] || return 1
  local code
  # On a connection failure/timeout curl prints "000" via -w (and exits non-zero); '|| true'
  # keeps that value instead of appending a second one. Empty or "000" => unreachable.
  code="$(curl -sS -m "$PROBE_TIMEOUT" -o /dev/null -w '%{http_code}' "$LICENSE_API_URL" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# POST {email} to the endpoint. Sets PROV_CODE (HTTP status) and PROV_BODY (response).
PROV_CODE=""; PROV_BODY=""
provision_request() {
  local tmp; tmp="$(mktemp)"
  PROV_CODE="$(curl -sS -m "$POST_TIMEOUT" -o "$tmp" -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -X POST "$LICENSE_API_URL" \
    -d "{\"email\":\"$1\",\"source\":\"gateway-ce-quickstart\"}" 2>/dev/null || true)"
  PROV_CODE="${PROV_CODE:-000}"
  PROV_BODY="$(cat "$tmp" 2>/dev/null || true)"; rm -f "$tmp"
}

# Interactive self-serve: ask for an email (up to 3 tries), POST it, react to the status.
# Echoes the license key on stdout on success; empty on give-up (caller then falls back).
# All user-facing text goes to stderr so stdout carries only the key.
self_serve() {
  local email lic tries=0
  while [ "$tries" -lt 3 ]; do
    tries=$(( tries + 1 ))
    printf "  Enter your business email to get a free license (attempt %d/3): " "$tries" >&2
    read -r email || return 0
    [ -n "$email" ] || { printf "  (email was empty)\n" >&2; continue; }
    provision_request "$email"
    case "$PROV_CODE" in
      200)
        lic="$(json_str "$PROV_BODY" license)"
        if [ -n "$lic" ]; then printf '%s' "$lic"; return 0; fi
        printf "  Unexpected response from the license service.\n" >&2 ;;
      400)
        printf "  That email looks invalid. Please try again.\n" >&2 ;;
      403)
        printf "  Please use a valid business email (personal domains aren't accepted).\n" >&2
        printf "  If you think this is a mistake, request one manually at %s\n" "$LICENSE_FORM_URL" >&2 ;;
      429)
        printf "  The license service is rate-limiting requests right now.\n" >&2
        return 0 ;;   # give up to the manual fallback
      *)
        printf "  License service error (HTTP %s). Falling back to manual.\n" "${PROV_CODE:-?}" >&2
        return 0 ;;
    esac
  done
  printf "  Couldn't provision after 3 attempts.\n" >&2
  return 0
}

# Manual fallback (today's flow): use GATEWAY_LICENSE_EMAIL-less env key, or prompt to
# paste a key requested from the website. Echoes the key on stdout (empty if none).
manual_paste() {
  if [ -t 0 ]; then
    printf "  Request a free key at %s\n" "$LICENSE_FORM_URL" >&2
    printf "  then paste it here: " >&2
    local k; read -r k || true; printf '%s' "$k"
  fi
}

# Orchestrates the whole license step: reuse -> self-serve (if online) -> manual paste.
# On success, writes GATEWAY_LICENSE_KEY to .env and sets it in the environment.
setup_license() {
  # 1. Reuse a key already provided (env var or .env) IF it's valid and not expired.
  local existing="" key=""
  if [ -n "${GATEWAY_LICENSE_KEY:-}" ]; then
    existing="$GATEWAY_LICENSE_KEY"
  elif [ -f .env ]; then
    existing="$(grep -E '^GATEWAY_LICENSE_KEY=.+' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
  fi
  if [ -n "$existing" ] && license_is_jwt "$existing"; then
    if license_expired "$existing"; then
      info "The stored license has expired -- provisioning a fresh one."
    else
      GATEWAY_LICENSE_KEY="$existing"
      ok "Reusing the valid license already in $PWD/.env (no request needed)"
      return 0
    fi
  fi

  # 2. Self-serve, if an endpoint is configured and reachable.
  if [ -n "$LICENSE_API_URL" ]; then
    if endpoint_reachable; then
      info "Provisioning your license..."
      if [ ! -t 0 ] && [ -n "${GATEWAY_LICENSE_EMAIL:-}" ]; then
        # Headless: provision once with the supplied email, no prompt.
        provision_request "$GATEWAY_LICENSE_EMAIL"
        [ "$PROV_CODE" = 200 ] && key="$(json_str "$PROV_BODY" license)"
      elif [ -t 0 ]; then
        key="$(self_serve)"
      fi
    else
      info "Can't reach the Conduktor license service (no internet, or the network blocks it)."
      info "If you have internet, check your connection and re-run for automatic setup."
      info "Otherwise, request a free key from any device with internet:"
    fi
  fi

  # 3. Manual fallback (today's behavior): paste a key from the website.
  [ -n "$key" ] || key="$(manual_paste)"

  [ -n "$key" ] || die "No license provided. Request one at $LICENSE_FORM_URL and re-run, or set GATEWAY_LICENSE_KEY=<key>."
  validate_license "$key"

  # Persist it. Write exactly ONE GATEWAY_LICENSE_KEY line: strip any existing (e.g.
  # just-expired) one first so .env never ends up with duplicates.
  local env_file="$PWD/.env"
  if [ -f .env ] && grep -q '^GATEWAY_LICENSE_KEY=' .env; then
    grep -v '^GATEWAY_LICENSE_KEY=' .env > .env.tmp 2>/dev/null || true
    mv .env.tmp .env
  fi
  printf 'GATEWAY_LICENSE_KEY=%s\n' "$key" >> .env
  # Make sure it actually landed before we tell the user it's saved.
  grep -q '^GATEWAY_LICENSE_KEY=.' .env || die "Could not write the license to $env_file"
  GATEWAY_LICENSE_KEY="$key"
  ok "License provisioned and saved to $env_file"
  info "Kept for next time: re-running reuses this file; delete it and the same email re-fetches the same license."
}

# In provisioning-only demo mode we only exercise the license flow, so we skip the
# Docker prerequisites and the stack fetch entirely -- no Docker or compose file needed.
if [ -z "${PROVISION_ONLY:-}" ]; then

# --- 1. prerequisites --------------------------------------------------------
step "1/5 Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "Docker is required. Install it: https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (the 'docker compose' command)."
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker and re-run."
ok "Docker and Docker Compose are ready"

# --- 2. locate or fetch the stack -------------------------------------------
step "2/5 Getting the stack"
if [ -f docker-compose.yaml ] || [ -f docker-compose.yml ]; then
  ok "Using the compose file in $(pwd)"
elif command -v git >/dev/null 2>&1; then
  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --quiet || info "couldn't update $REPO_DIR, using the existing copy"
  elif [ -d "$REPO_DIR" ]; then
    info "$REPO_DIR exists but isn't a git checkout, using it as-is"
  else
    git clone --quiet "$REPO_URL" "$REPO_DIR" || die "git clone failed"
  fi
  cd "$REPO_DIR"
  ok "Stack ready in $(pwd)"
else
  die "No compose file here and git is not installed. Install git, or run this from a cloned repo."
fi

fi  # end: skipped in PROVISION_ONLY mode

# --- 3. license --------------------------------------------------------------
step "3/5 Setting up your license"
setup_license

# Demo / testing hook: stop after the license is set up, before touching Docker.
# Lets you showcase JUST the email -> license -> .env flow (e.g. against the mock API in
# ./mock-license-api) without downloading images or starting the stack.
if [ -n "${PROVISION_ONLY:-}" ]; then
  ok "Provisioning-only mode: license ready, skipping Docker startup."
  exit 0
fi

# --- 4. download images ------------------------------------------------------
# Pull up front so the slow first-run download is visible. 'docker compose up'
# does this silently (and we redirect its output below to draw our own bar), so
# without this step the start phase would sit at 0% for minutes and look hung.
#
# We do NOT let Docker draw the progress itself: its TTY renderer reserves a tall
# multi-line region (one line per service + layer) and, on completion, leaves a
# big blank gap or overflows the pane -- especially in a narrow/split terminal.
# Instead we run the pull in the background with its output redirected to a log,
# and drive the same single-line bar used by the start phase, which we fully
# control. A spinner in the label keeps it visibly alive while a large layer
# downloads (the bar itself advances once per service that finishes).
step "4/5 Downloading images"
info "(first run downloads a few GB; cached images are skipped)"

TOTAL_SVC=$(docker compose config --services 2>/dev/null | grep -c . || true)
[ "${TOTAL_SVC:-0}" -gt 0 ] 2>/dev/null || TOTAL_SVC=1

PULL_LOG="$(mktemp)"
# Run in a subshell that records the exit code on completion. We poll for that
# sentinel rather than 'kill -0', which can stay true for an unreaped zombie.
( docker compose pull >"$PULL_LOG" 2>&1; echo $? >"$PULL_LOG.code" ) &

if [ -z "$IS_TTY" ]; then echo "  Pulling images for $TOTAL_SVC services..."; fi
SPIN='|/-\'; spin_i=0
while [ ! -f "$PULL_LOG.code" ]; do
  if [ -n "$IS_TTY" ]; then
    # A service is done once Compose prints "Pulled" / "Skipped" / "Error" for it.
    done_n=$(grep -cE ' (Pulled|Skipped|Error)' "$PULL_LOG" 2>/dev/null || true); done_n=${done_n:-0}
    [ "$done_n" -gt "$TOTAL_SVC" ] && done_n=$TOTAL_SVC
    # '|| true': before any service starts, grep matches nothing and, under
    # 'set -o pipefail', a failing command substitution would abort the script.
    cur=$(grep -E ' Pulling *$' "$PULL_LOG" 2>/dev/null | tail -1 | awk '{print $1}' || true)
    frame=${SPIN:spin_i:1}; spin_i=$(( (spin_i + 1) % 4 ))
    draw_bar "$done_n" "$TOTAL_SVC" "$frame downloading ${cur:-}"
  fi
  sleep 0.2
done

if [ "$(cat "$PULL_LOG.code" 2>/dev/null)" != 0 ]; then
  [ -n "$IS_TTY" ] && printf "\n"
  tail -n 15 "$PULL_LOG" >&2
  die "Failed to download images (see above). Check your network, then re-run. Clean up with 'docker compose down'."
fi
if [ -n "$IS_TTY" ]; then draw_bar "$TOTAL_SVC" "$TOTAL_SVC" "done"; printf "\n"; fi
ok "All images present"

# --- 5. start ----------------------------------------------------------------
step "5/5 Starting Kafka, the Gateway, and the consumers"

# Run 'up' in the background so we can draw a live progress bar while it works.
# (It would otherwise block until everything is healthy, because the consumers
# depend on the Gateway being healthy, leaving nothing to show.)
UP_LOG="$(mktemp)"
docker compose up -d >"$UP_LOG" 2>&1 &
UP_PID=$!

# Core services with healthchecks. Each scores 1 once started, 2 once healthy,
# so the bar grows as the stack comes up (started -> healthy) rather than faking it.
CORE_SERVICES=(kafka karapace "$GATEWAY_CONTAINER")
MAX_SCORE=$(( ${#CORE_SERVICES[@]} * 2 ))

gw=""
if [ -z "$IS_TTY" ]; then echo "  Waiting for the Gateway to become healthy..."; fi
for _ in $(seq 1 120); do
  score=0
  for svc in "${CORE_SERVICES[@]}"; do
    s="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}down{{end}}{{end}}' "$svc" 2>/dev/null || echo down)"
    case "$s" in
      healthy)                      score=$(( score + 2 )) ;;
      starting|running|unhealthy)   score=$(( score + 1 )) ;;
    esac
  done
  gw="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$GATEWAY_CONTAINER" 2>/dev/null || echo missing)"
  if [ "$gw" = "healthy" ]; then
    if [ -n "$IS_TTY" ]; then draw_bar "$MAX_SCORE" "$MAX_SCORE" "ready"; printf "\n"; fi
    ok "All services healthy"
    break
  fi
  # If 'up' exited before the Gateway is healthy, something went wrong.
  if ! kill -0 "$UP_PID" 2>/dev/null && ! wait "$UP_PID"; then
    if [ -n "$IS_TTY" ]; then printf "\n"; fi
    cat "$UP_LOG" >&2
    die "docker compose up failed (see output above). Clean up with 'docker compose down'."
  fi
  if [ -n "$IS_TTY" ]; then draw_bar "$score" "$MAX_SCORE" "starting services..."; fi
  sleep 1
done

wait "$UP_PID" 2>/dev/null || true

if [ "$gw" != "healthy" ]; then
  if [ -n "$IS_TTY" ]; then printf "\n"; fi
  lic="$(docker logs "$GATEWAY_CONTAINER" 2>&1 | grep -iE 'licen|expir|invalid|unauthor' | tail -3 || true)"
  if [ -n "$lic" ]; then printf "${RED}  The Gateway log mentions a possible license problem:${RESET}\n%s\n" "$lic" >&2; fi
  die "Gateway did not become healthy in time. Inspect with 'docker compose logs $GATEWAY_CONTAINER', clean up with 'docker compose down'."
fi

# The data generator runs continuously. Wait until it has actually produced to the demo topic
# (through the Gateway, from a consumer), so the walkthrough never reads an empty topic.
# Best-effort: warn rather than fail.
DEMO_TOPIC=customers
seeded=
for _ in $(seq 1 60); do
  if docker exec kafka-consumer-a kcat -q -b "$GATEWAY_CONTAINER:9092" -t "$DEMO_TOPIC" -C -e -c 1 -o beginning \
       -X security.protocol=SASL_PLAINTEXT -X sasl.mechanism=PLAIN \
       -X sasl.username=consumer-a -X sasl.password=consumer-a-secret 2>/dev/null | grep -q .; then
    seeded=1; break
  fi
  sleep 1
done
if [ -n "$seeded" ]; then
  ok "Sample data is flowing"
else
  info "No data in '$DEMO_TOPIC' yet; the generator may need another moment"
fi

# --- done --------------------------------------------------------------------
cat <<EOF

$(printf "${GREEN}${BOLD}Ready.${RESET}") Your private Kafka cluster is reachable only through the Gateway.

Run the guided walkthrough to see it work:

  ./demo.sh

Stop everything with:  docker compose down
EOF

# Offer to run the walkthrough now, if we're interactive.
if [ -n "$IS_TTY" ] && [ -t 0 ] && [ -x ./demo.sh ]; then
  printf "\n  Walk through the demo now? [Y/n] "
  read -r ans
  case "${ans:-}" in
    [Nn]*) ;;
    *) ./demo.sh ;;
  esac
fi
