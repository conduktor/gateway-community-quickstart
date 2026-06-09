#!/usr/bin/env bash
#
# Tears down the Conduktor Gateway Community Edition quickstart.
# Removes containers and volumes (a fresh ./start.sh regenerates demo data).
# Pass --keep to stop the containers but keep the volumes.
#
set -euo pipefail

if [ -t 1 ]; then BOLD='\033[1m'; GREEN='\033[0;32m'; RESET='\033[0m'; else BOLD=''; GREEN=''; RESET=''; fi

if [ "${1:-}" = "--keep" ]; then
  printf "${BOLD}▸ Stopping the stack (keeping volumes)${RESET}\n"
  docker compose down
else
  printf "${BOLD}▸ Stopping the stack and removing volumes${RESET}\n"
  docker compose down -v
fi

printf "${GREEN}  ✓ Done. Run ./start.sh to bring it back up.${RESET}\n"
