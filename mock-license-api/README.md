# Mock license API (self-serve demo)

A runnable stand-in for the real **"email -> license"** endpoint, so we can show Matt the
exact self-serve flow we want *before* the real backend exists. It implements the contract
in [`../docs/self-serve-license-endpoint.md`](../docs/self-serve-license-endpoint.md).

**What it returns:** if it finds a real license (`GATEWAY_LICENSE_KEY` in the repo's
`.env`, or a `MOCK_LICENSE_KEY` env var) it hands **that** back, so the demo is
end-to-end real: the Gateway actually accepts the key and the full stack comes up. If it
finds none, it mints a **fake but well-formed** token, enough to demo the script's flow
and error branches but which the Gateway would reject. The startup banner tells you which
mode you're in.

> Either way the mock **signs nothing itself**. Serving your existing key just borrows a
> license that was already validly signed. The real endpoint must *generate and sign* one
> per email with the Gateway's key; that's the whole point of the doc.

## Quickest way: see it as a user

```bash
./mock-license-api/demo.sh              # online: type an email, get a license
OFFLINE=1 ./mock-license-api/demo.sh    # air-gap: probe fails -> form + paste fallback
KEEP=1    ./mock-license-api/demo.sh    # persistent: shows re-run behaviors (below)
```

The default run starts the mock, then runs the install script in a fresh temp dir (so
there's no existing `.env` to reuse) and drops you straight into the prompt. Type a
business email to get a license, or a personal one (`@gmail.com`) to see the rejection.
Stops the mock and cleans up when you exit. This is the whole user experience in one
command.

**`OFFLINE=1`** simulates an air-gapped / blocked network by pointing the script at a
dead port. Note that turning off your Wi-Fi does NOT do this: the mock lives on
`127.0.0.1`, and localhost stays reachable with no internet, so the probe correctly
succeeds. In production the endpoint is a real internet host, so no connectivity means
the probe fails and the script falls back to the manual form + paste flow, which is what
this mode shows.

**`KEEP=1`** stores demo state in `/tmp/gateway-ce-demo` instead of a throwaway dir, so
you can see the behaviors that only show up across runs:

```bash
KEEP=1 ./mock-license-api/demo.sh    # run 1: provisions, saves .env
KEEP=1 ./mock-license-api/demo.sh    # run 2: reuses the saved license, ZERO API calls
rm /tmp/gateway-ce-demo/.env
KEEP=1 ./mock-license-api/demo.sh    # run 3: same email -> mock logs "returning
                                     #        EXISTING", the SAME key comes back
rm -rf /tmp/gateway-ce-demo          # reset
```

Run 3 is the "one active license per user" rule from the spec (§3): losing or deleting
your `.env` never mints a duplicate; the POST is the lookup.

The sections below are for driving the pieces manually.

## Run it

Python 3 standard library only, no dependencies:

```bash
python3 mock-license-api/server.py          # http://127.0.0.1:8080
```

Leave it running in one terminal.

## Demo A — the happy path (what we want the UX to be)

In another terminal, point the install script at the mock and run it in provisioning-only
mode (no Docker, no image download; it stops right after the license is set up):

```bash
LICENSE_API_URL=http://127.0.0.1:8080/gateway/community-edition/license \
PROVISION_ONLY=1 ./start.sh
```

You'll be asked for a business email, and a license lands in `.env` without ever leaving
the terminal. Run it again: it **reuses** `.env` and makes no call. Delete `.env` and
re-run with the same email: you get the **same** license back (one active license per
user), not a new one.

## Demo B — the branches (what the script has to handle)

Hit the endpoint directly to show each response:

```bash
URL=http://127.0.0.1:8080/gateway/community-edition/license
curl -s $URL -d '{"email":"jane@acme.com"}'   # 200  -> { license, expires_at }
curl -s $URL -d '{"email":"jane@gmail.com"}'  # 403  -> invalid_business_email
curl -s $URL -d '{"email":"nope"}'            # 400  -> invalid_email
```

Or drive them through the script's UX:

- **Business email** -> license saved.
- **Personal email** (`@gmail.com`) -> "please use a valid business email", re-prompts (3
  tries), then points to the manual form.
- **Offline / blocked** -> point `LICENSE_API_URL` at a dead port to simulate an air-gap:
  ```bash
  LICENSE_API_URL=http://127.0.0.1:59999/x PROVISION_ONLY=1 ./start.sh
  ```
  The script detects it can't reach the service and falls back to today's "request on the
  website and paste it here" flow.

## What the mock logs (and the real one should too)

Every outcome prints to the mock's stdout (issued / returned-existing / 400 / 403 / 429).
This is the point from the doc: **rejections never create a HubSpot contact, so the only
place they're visible is the API's own logs/metrics.** Watch that terminal during the demo.

## The pitch to Matt

> "Here's the flow I want. The script does the prompting, the offline fallback, and the
> `.env` handling. All you build is this one endpoint: `POST { email } -> { license }`,
> signed with the Gateway's key, plus the HubSpot contact write on success. This mock is
> the shape of it. Spec: `docs/self-serve-license-endpoint.md`."

## Not included (on purpose)

Real signing, real business-email validation, and the HubSpot write are the real backend's
job (they already exist internally, per the doc). The mock fakes them just enough to make
the script's behavior real.
