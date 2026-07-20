#!/usr/bin/env python3
"""
Mock Conduktor Gateway CE license endpoint.

A stand-in for the real "email -> license" service, so we can demo the exact self-serve
flow we want *before* the real backend exists. It implements the contract described in
docs/self-serve-license-endpoint.md:

  POST /gateway/community-edition/license   { "email", "source" }  -> { "license", "expires_at" }
  GET  /health                                                     -> 200 (reachability probe)

Behavior it demonstrates (all the branches the install script has to handle):
  * 200  valid business email               -> returns a (fake but well-formed) license JWT
  * 403  personal-email domain              -> invalid_business_email
  * 400  malformed email                    -> invalid_email
  * 429  too many requests from one client  -> rate_limited
  * "one active license per user"           -> the same email gets the SAME license back
                                               until it expires (idempotent), so deleting
                                               .env and re-requesting does not mint a new key.

It is NOT production code and signs nothing real: the JWT signature is fake. The install
script only sanity-checks the token shape + expiry, so this is enough to demo the flow.
The real Gateway would reject the fake signature -- which is exactly why the real endpoint
must sign with the Gateway's key (see the doc).

Run:  python3 server.py            # listens on http://127.0.0.1:8080
      PORT=9000 python3 server.py
No dependencies -- Python 3 standard library only.
"""

import base64
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- config ------------------------------------------------------------------
PORT = int(os.environ.get("PORT", "8080"))
PATH = "/gateway/community-edition/license"
TTL_SECONDS = int(os.environ.get("TTL_SECONDS", str(365 * 24 * 3600)))  # 1 year
RATE_LIMIT = int(os.environ.get("RATE_LIMIT", "20"))       # max requests...
RATE_WINDOW = int(os.environ.get("RATE_WINDOW", "60"))     # ...per this many seconds, per client IP

# Personal-email domains rejected as "not a business email". The real service delegates
# this to the internal validator; here we keep a small illustrative list.
PERSONAL_DOMAINS = {
    "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk", "hotmail.com",
    "outlook.com", "live.com", "icloud.com", "me.com", "aol.com", "proton.me",
    "protonmail.com", "gmx.com", "mail.com", "yandex.com", "zoho.com",
}
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

# --- in-memory state (resets when the process restarts) ----------------------
# email -> {"license": <jwt>, "exp": <epoch>}   (the "one active license per user" store)
ISSUED = {}
# client ip -> list[timestamps]                 (the rate-limit window)
HITS = {}


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(seg: str) -> bytes:
    pad = "=" * (-len(seg) % 4)
    return base64.urlsafe_b64decode(seg + pad)


def jwt_exp(token: str) -> int:
    """Read the 'exp' claim from a JWT payload; 0 if not present/parseable."""
    try:
        payload = json.loads(b64url_decode(token.split(".")[1]))
        return int(payload.get("exp", 0))
    except Exception:
        return 0


def load_real_license() -> str:
    """
    Return a REAL, correctly-signed license if we can find one, so the demo works
    end-to-end (the Gateway will actually accept it). Lookup order:
      1. MOCK_LICENSE_KEY env var
      2. GATEWAY_LICENSE_KEY env var
      3. GATEWAY_LICENSE_KEY= in the repo's .env (parent dir of this script)
    Returns "" if none found -> the mock mints a fake (unverifiable) token instead.
    """
    for var in ("MOCK_LICENSE_KEY", "GATEWAY_LICENSE_KEY"):
        val = os.environ.get(var, "").strip()
        if val:
            return val
    env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")
    try:
        with open(env_path) as fh:
            for line in fh:
                if line.startswith("GATEWAY_LICENSE_KEY="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


REAL_LICENSE = load_real_license()


def mint_license(email: str, now: int) -> dict:
    """
    Return a license for this email. If we found a real signed key (see
    load_real_license), hand that back so the demo is end-to-end real. Otherwise build a
    fake-but-well-formed JWT good enough for the script's sanity check (the real endpoint
    signs with the Gateway's key; the mock can't).
    """
    if REAL_LICENSE:
        exp = jwt_exp(REAL_LICENSE) or (now + TTL_SECONDS)
        return {"license": REAL_LICENSE, "exp": exp}
    exp = now + TTL_SECONDS
    header = {"alg": "ES256", "typ": "JWT"}
    payload = {
        "sub": email,
        "iss": "mock-license-api",
        "iat": now,
        "exp": exp,
        "plan": "community",
    }
    signature = b64url(b"MOCK-SIGNATURE-not-verifiable-real-service-signs-with-gateway-key")
    token = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(payload).encode())}.{signature}"
    return {"license": token, "exp": exp}


def rate_limited(ip: str, now: int) -> bool:
    window = [t for t in HITS.get(ip, []) if t > now - RATE_WINDOW]
    window.append(now)
    HITS[ip] = window
    return len(window) > RATE_LIMIT


def iso(epoch: int) -> str:
    """Format an epoch as the ISO 8601 string the contract specifies for expires_at."""
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    # Operational visibility: every outcome is logged, since rejections never reach the CRM.
    print(f"  [mock-api] {msg}", flush=True)


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, body: dict) -> None:
        blob = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def log_message(self, *args):  # silence the default noisy logging
        pass

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", ""):
            self._send(200, {"status": "ok"})
        else:
            self._send(404, {"error": "not_found", "message": "Try POST " + PATH})

    def do_POST(self):
        now = int(time.time())
        ip = self.client_address[0]

        if self.path.rstrip("/") != PATH.rstrip("/"):
            self._send(404, {"error": "not_found", "message": "Try POST " + PATH})
            return

        # Rate limit (the abuse control that survives .env deletion / reloads).
        if rate_limited(ip, now):
            log(f"429 rate_limited ip={ip}")
            self._send(429, {"error": "rate_limited", "message": "Too many requests. Try again shortly."})
            return

        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send(400, {"error": "invalid_email", "message": "Body must be JSON."})
            return

        email = str(data.get("email", "")).strip().lower()
        source = data.get("source", "")

        # 400: malformed email.
        if not EMAIL_RE.match(email):
            log(f"400 invalid_email email={email!r} source={source!r}")
            self._send(400, {"error": "invalid_email", "message": "That doesn't look like a valid email."})
            return

        # 403: personal-email domain (not a business email). No contact is created.
        domain = email.rsplit("@", 1)[-1]
        if domain in PERSONAL_DOMAINS:
            log(f"403 invalid_business_email email={email} (rejected, NOT written to CRM)")
            self._send(403, {
                "error": "invalid_business_email",
                "message": "Please use a valid business email address.",
            })
            return

        # 200: idempotent issue -- return the existing active license if we have one.
        existing = ISSUED.get(email)
        if existing and existing["exp"] > now:
            log(f"200 returning EXISTING license email={email} (one-active-license-per-user)")
            # (real service would also refresh the HubSpot contact's fields here)
            self._send(200, {"license": existing["license"], "expires_at": iso(existing["exp"])})
            return

        minted = mint_license(email, now)
        ISSUED[email] = minted
        log(f"200 issued NEW license email={email} source={source!r} "
            f"(real service would: sign w/ Gateway key + upsert HubSpot contact "
            f"[License Sent / Sent Date / Expiry / Source])")
        self._send(200, {"license": minted["license"], "expires_at": iso(minted["exp"])})


def main():
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError as e:
        print(f"  [mock-api] cannot bind port {PORT}: {e}\n"
              f"  Something is already using it. Stop it (pkill -f mock-license-api/server.py) "
              f"or pick another: PORT=8090 python3 mock-license-api/server.py", flush=True)
        sys.exit(1)
    base = f"http://127.0.0.1:{PORT}"
    if REAL_LICENSE:
        mode = "serving your REAL license (from .env / env) -- works end-to-end with the Gateway"
    else:
        mode = "no real license found -> minting FAKE tokens (flow demo only; Gateway will reject)"
    print(f"""
  Mock Conduktor CE license API listening on {base}
  Mode: {mode}
    endpoint : POST {base}{PATH}
    health   : GET  {base}/health

  Point the install script at it:
    LICENSE_API_URL={base}{PATH} PROVISION_ONLY=1 ./start.sh

  Try the branches directly:
    business email -> 200 :  curl -s {base}{PATH} -d '{{"email":"you@acme.com"}}'
    personal email -> 403 :  curl -s {base}{PATH} -d '{{"email":"you@gmail.com"}}'
    malformed      -> 400 :  curl -s {base}{PATH} -d '{{"email":"nope"}}'

  Ctrl+C to stop.
""", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  bye", flush=True)
        sys.exit(0)


if __name__ == "__main__":
    main()
