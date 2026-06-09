#!/usr/bin/env bash
#
# Conduktor Gateway Community Edition quickstart bootstrapper.
#
#
set -euo pipefail

# Clean up the temp log on exit (including Ctrl+C); harmless if it was never created.
trap 'rm -f "${UP_LOG:-}" 2>/dev/null || true' EXIT

REPO_URL="https://github.com/conduktor/gateway-community-quickstart.git"
REPO_DIR="gateway-community-quickstart"
GATEWAY_CONTAINER="conduktor-gateway"

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

# --- 1. prerequisites --------------------------------------------------------
step "1/4 Checking prerequisites"
command -v docker >/dev/null 2>&1 || die "Docker is required. Install it: https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (the 'docker compose' command)."
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker and re-run."
ok "Docker and Docker Compose are ready"

# --- 2. locate or fetch the stack -------------------------------------------
step "2/4 Getting the stack"
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

# --- 3. license --------------------------------------------------------------
step "3/4 Setting up your license"
if [ -f .env ] && grep -q '^GATEWAY_LICENSE_KEY=.\+' .env; then
  ok "Reusing the license already in .env"
else
  if [ -z "${GATEWAY_LICENSE_KEY:-}" ]; then
    if [ -t 0 ]; then
      printf "  Paste your Gateway Community Edition license key (free, request at https://conduktor.io/gateway/community-edition): "
      read -r GATEWAY_LICENSE_KEY
    else
      die "No license found. Re-run with: GATEWAY_LICENSE_KEY=<key> bash <(curl -fsSL <url>)"
    fi
  fi
  [ -n "${GATEWAY_LICENSE_KEY:-}" ] || die "License key was empty."
  printf 'GATEWAY_LICENSE_KEY=%s\n' "$GATEWAY_LICENSE_KEY" >> .env
  ok "License saved to .env"
fi

# --- 4. start ----------------------------------------------------------------
step "4/4 Starting Kafka, the Gateway, and the consumers"

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
BAR_WIDTH=28

draw_bar() { # $1 = score, $2 = max, $3 = label
  local score=$1 max=$2 label=$3 filled i pct
  filled=$(( score * BAR_WIDTH / max ))
  pct=$(( score * 100 / max ))
  printf "\r  ["
  for (( i = 0; i < BAR_WIDTH; i++ )); do
    if [ "$i" -lt "$filled" ]; then printf "█"; else printf "░"; fi
  done
  printf "] %3d%%  %-20s" "$pct" "$label"
}

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
