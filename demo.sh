#!/usr/bin/env bash
#
# Guided walkthrough of the Gateway Community Edition quickstart.
# Run it after ./start.sh. Each step shows the command, waits for Enter, then runs it for you.
#
set -uo pipefail

if [ -t 1 ]; then
  BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; DIM=$'\033[2m'; RED=$'\033[0;31m'; RESET=$'\033[0m'
else
  BOLD=''; GREEN=''; DIM=''; RED=''; RESET=''
fi

GW=conduktor-gateway
SR=http://karapace:8081

# --- preflight ---------------------------------------------------------------
status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$GW" 2>/dev/null || echo missing)"
if [ "$status" != "healthy" ]; then
  printf "${RED}The Gateway isn't ready (status: %s).${RESET}\n" "$status" >&2
  printf "Run ./start.sh first, then re-run ./demo.sh.\n" >&2
  exit 1
fi

step() { # $1 = explanation, $2 = command
  printf "\n${BOLD}%s${RESET}\n" "$1"
  printf "${DIM}\$ %s${RESET}\n" "$2"
  if [ -t 0 ]; then printf "  (Enter to run, Ctrl+C to quit) "; read -r _; fi
  eval "$2" || true
}

cat <<EOF

${BOLD}Gateway Community Edition: guided walkthrough${RESET}

Kafka sits in its own private network. Two consumers sit in two other networks and can
only reach Kafka through the Gateway. Let's prove it, one step at a time.
EOF

step "1) Can either consumer reach Kafka directly? They're in separate networks, so neither should." \
  "docker exec kafka-consumer-a kcat -b kafka:9092 -L -m 5; docker exec kafka-consumer-b kcat -b kafka:9092 -L -m 5"
printf "${DIM}   -> Neither resolves 'kafka:9092': there's no route from either VPC to the cluster.${RESET}\n"

step "2) Now consumer-a reaches the SAME cluster through the Gateway, decoding Avro via the registry." \
  "docker exec kafka-consumer-a kcat -b $GW:9092 -t customers -C -e -c 3 -s value=avro -r $SR -X security.protocol=SASL_PLAINTEXT -X sasl.mechanism=PLAIN -X sasl.username=consumer-a -X sasl.password=consumer-a-secret"
printf "${DIM}   -> Readable JSON. consumer-a never touched the cluster directly; the Gateway relayed it.${RESET}\n"

step "3) consumer-b, in a SEPARATE VPC and as a different principal, does exactly the same." \
  "docker exec kafka-consumer-b kcat -b $GW:9092 -t customers -C -e -c 3 -s value=avro -r $SR -X security.protocol=SASL_PLAINTEXT -X sasl.mechanism=PLAIN -X sasl.username=consumer-b -X sasl.password=consumer-b-secret"
printf "${DIM}   -> Two isolated VPCs, one Gateway, one attachment to the cluster.${RESET}\n"

step "4) See what the Gateway rewrote: the private kafka:9092 becomes an address the client can reach." \
  "docker logs $GW 2>&1 | grep 'Rewriting METADATA' | sed 's/, MetadataResponseData.*//' | tail -3"

printf "\n${GREEN}${BOLD}That's the demo.${RESET} Stop everything with: docker compose down (or ./stop.sh)\n"
