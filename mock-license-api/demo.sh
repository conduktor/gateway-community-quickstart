#!/usr/bin/env bash
#
# One-command self-serve demo. Starts the mock license API, then runs the install
# script in a FRESH temp directory (so there's no existing .env to reuse) and drops
# you straight into the user experience: it asks for your email and provisions a
# license, exactly as a real user would see it.
#
# Usage:  ./mock-license-api/demo.sh              # online demo (self-serve flow)
#         OFFLINE=1 ./mock-license-api/demo.sh    # air-gap demo (manual fallback flow)
#         KEEP=1    ./mock-license-api/demo.sh    # persistent dir: shows reuse across runs
#
# KEEP=1 stores the demo's .env in /tmp/gateway-ce-demo instead of a throwaway dir, so
# re-running shows the RE-RUN behaviors the one-shot demo can't: a second run reuses the
# saved license (no API call), and deleting the .env then re-entering the same email
# returns the SAME key (one active license per user). Reset with: rm -rf /tmp/gateway-ce-demo
#
# Why OFFLINE=1 exists: the mock runs on 127.0.0.1, and localhost is reachable even
# with Wi-Fi off -- so turning off your internet does NOT trigger the offline branch
# here. OFFLINE=1 points the script at a dead port instead, which is exactly what an
# unreachable api.conduktor.io looks like to the script in the real world.
#
# Stops the mock and cleans up automatically when you exit.
#
set -euo pipefail

PORT="${PORT:-8080}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
URL="http://127.0.0.1:${PORT}/gateway/community-edition/license"

if [ -n "${KEEP:-}" ]; then
  WORKDIR="/tmp/gateway-ce-demo"
  mkdir -p "$WORKDIR"
else
  WORKDIR="$(mktemp -d)"
fi
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true   # reap it quietly (no "Terminated" notice)
  fi
  # Persistent mode keeps the dir (that's the point); one-shot mode cleans up.
  [ -n "${KEEP:-}" ] || rm -rf "$WORKDIR"
}
trap cleanup EXIT

if [ -n "${OFFLINE:-}" ]; then
  # ---- Air-gap demo: no mock at all; the endpoint is simply unreachable. -------------
  URL="http://127.0.0.1:59999/gateway/community-edition/license"   # nothing listens here
  cat <<EOF
> OFFLINE demo: simulating an air-gapped / blocked network.
  (no mock started; the script will probe the endpoint, fail, and fall back to
   the manual "request on the website and paste" flow -- today's behavior)

  When prompted, paste any well-formed key to finish, e.g.:
    eyJhbGciOiJFUzI1NiJ9.eyJleHAiOjIwMDAwMDAwMDB9.c2ln
--------------------------------------------------------------------------
EOF
  cd "$WORKDIR"
  LICENSE_API_URL="$URL" PROVISION_ONLY=1 bash "$REPO/start.sh" || true
  echo "--------------------------------------------------------------------------"
  if [ -f "$WORKDIR/.env" ]; then
    echo "  License was stored here (this run's working dir):"
    echo "    $WORKDIR/.env"
    echo "    $(sed 's/\(GATEWAY_LICENSE_KEY=.\{16\}\).*/\1.../' "$WORKDIR/.env")"
    if [ -n "${KEEP:-}" ]; then
      echo "    (persistent demo dir -- re-run with KEEP=1 to see it get REUSED)"
    else
      echo "    (temp dir, removed on exit -- in a real install this is your project's .env)"
    fi
  fi
  echo
  if [ -n "${KEEP:-}" ]; then
    echo "> Done. State kept in $WORKDIR (reset: rm -rf $WORKDIR)"
  else
    echo "> Done. Temp dir cleaned up."
  fi
  exit 0
fi

# ---- Online demo: start the mock and run the self-serve flow against it. -------------

# Refuse to run against something already on this port (a stale server would masquerade).
if curl -fsS -m 1 -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; then
  echo "  Port ${PORT} is already in use. Stop it (pkill -f mock-license-api/server.py)"
  echo "  or re-run with another port:  PORT=8090 $0"
  exit 1
fi

echo "> Starting the mock license API on port ${PORT}..."
PORT="$PORT" python3 "$HERE/server.py" >"$WORKDIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for OUR server to answer (and confirm it's still alive, i.e. it bound the port).
up=""
for _ in $(seq 1 25); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi   # it died (e.g. bind failed)
  if curl -fsS -m 1 -o /dev/null "http://127.0.0.1:${PORT}/health" 2>/dev/null; then up=1; break; fi
  sleep 0.2
done
if [ -z "$up" ]; then
  echo "  Mock API failed to start:"; sed 's/^/    /' "$WORKDIR/server.log"; exit 1
fi
sleep 0.3   # let the startup banner land in the log
grep -m1 "Mode:" "$WORKDIR/server.log" || true

if [ -n "${KEEP:-}" ]; then
  if [ -f "$WORKDIR/.env" ]; then
    cat <<EOF

  KEEP mode: persistent state in $WORKDIR
  A license was saved by a previous run, so this run should REUSE it
  (no prompt, no API call). To see "same key back" instead, exit and:
    rm $WORKDIR/.env && KEEP=1 $0   -> same email returns the SAME key
--------------------------------------------------------------------------
EOF
  else
    cat <<EOF

  KEEP mode: persistent state in $WORKDIR (no license saved yet, so this
  run will PROVISION one and keep it for the next run).

  Try it a few ways:
    - a business email (e.g. you@conduktor.io)  -> gets a license
    - a personal email (e.g. you@gmail.com)     -> rejected, re-prompts

  Watch this same terminal after: the mock logs every outcome.
--------------------------------------------------------------------------
EOF
  fi
else
  cat <<EOF

  Now running the install script as a brand-new user would see it.
  (fresh temp dir, no license yet, so it will PROVISION one)

  Try it a few ways:
    - a business email (e.g. you@conduktor.io)  -> gets a license
    - a personal email (e.g. you@gmail.com)     -> rejected, re-prompts
    - press Ctrl+C to bail out

  Other modes:  OFFLINE=1 $0   (air-gap fallback)
                KEEP=1 $0      (persistent state: reuse + same-key-back)

  Watch this same terminal after: the mock logs every outcome.
--------------------------------------------------------------------------
EOF
fi

# Run the REAL script in the fresh dir, interactively. PROVISION_ONLY stops it right
# after the license is set up (no Docker), so this stays a quick license-flow demo.
cd "$WORKDIR"
LICENSE_API_URL="$URL" PROVISION_ONLY=1 bash "$REPO/start.sh" || true

sleep 0.3   # let the last request's log line land
echo "--------------------------------------------------------------------------"
if [ -f "$WORKDIR/.env" ]; then
  echo "  License was stored here (this run's working dir):"
  echo "    $WORKDIR/.env"
  echo "    $(sed 's/\(GATEWAY_LICENSE_KEY=.\{16\}\).*/\1.../' "$WORKDIR/.env")"
  if [ -n "${KEEP:-}" ]; then
    echo "    (persistent demo dir -- re-run with KEEP=1 to see it get REUSED)"
  else
    echo "    (temp dir, removed on exit -- in a real install this is your project's .env)"
  fi
  echo
fi
echo "  Mock API log (every request/outcome):"
grep "mock-api" "$WORKDIR/server.log" | sed 's/^/    /' || echo "    (no requests logged)"
echo
if [ -n "${KEEP:-}" ]; then
  echo "> Done. Mock stopped. State kept in $WORKDIR (reset: rm -rf $WORKDIR)"
  echo "  Re-run KEEP=1 $0 to see the license REUSED with no API call;"
  echo "  or rm $WORKDIR/.env first to see the SAME key come back for the same email."
else
  echo "> Done. Mock stopped, temp dir cleaned up."
fi
