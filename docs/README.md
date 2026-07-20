# Self-serve license: what's in here and how to demo it

This folder documents the **Gateway CE self-serve license** work. The idea in one line:
today a user manually requests a key on the website and pastes it into `start.sh`;
self-serve makes the script do it for them (**email in, license out**), with the manual
flow kept as the fallback for offline or air-gapped networks.

## The pieces

| Piece | What it is |
|---|---|
| [`self-serve-license-endpoint.md`](self-serve-license-endpoint.md) | **The spec.** The contract for the one endpoint the backend builds, who owns what, the CRM behavior, and every flow branch. Read this first. |
| [`../start.sh`](../start.sh) | **The real client.** Step 3 ("Setting up your license") implements the spec's script side: probe, prompt, POST, fallbacks, `.env` handling. Ships safely today: with `LICENSE_API_URL` unset it behaves exactly like the current manual flow. |
| [`../mock-license-api/`](../mock-license-api/) | **A runnable stand-in for the endpoint.** ~200 lines of dependency-free Python implementing the exact contract (200 / 400 / 403 / 429, idempotency, outcome logging), so the flow can be experienced before the real backend exists. |

## Demo it in one command

From the repo root:

```bash
./mock-license-api/demo.sh              # online: type an email, get a license
OFFLINE=1 ./mock-license-api/demo.sh    # air-gap: probe fails, manual form + paste fallback
KEEP=1    ./mock-license-api/demo.sh    # persistent state: shows reuse + same-key-back across runs
```

All run the real `start.sh` outside the repo (your repo `.env` is never touched) and stop
right after the license step (no Docker needed). The default and `OFFLINE` runs use a
throwaway temp dir; `KEEP=1` persists state in `/tmp/gateway-ce-demo` so re-run behaviors
are visible (reset with `rm -rf /tmp/gateway-ce-demo`).

What to try in the online demo, mapped to the spec:

| Do this | You see (spec section) |
|---|---|
| Enter a business email | License provisioned and saved to `.env` (§1 success, Path A) |
| Enter `you@gmail.com` | "Please use a valid business email" and a re-prompt (§1 `403`) |
| Enter `nope` | "That email looks invalid" and a re-prompt (§1 `400`) |
| Fail 3 times | Script stops asking and points to the form (§2 attempt cap, Path B) |
| Re-run after success (`KEEP=1` runs) | Reuses `.env`, no API call (§5 flow) |
| Delete `.env`, same email (`KEEP=1` runs) | The **same** key comes back, not a new one (§3 one active license per user) |
| Watch the mock's log | `issued NEW` / `returning EXISTING` / rejections, which never reach the CRM (§2) |

The `OFFLINE=1` demo shows the fallback branch: the script probes the endpoint, cannot
reach it, explains why, and drops to today's "request a key on the website and paste it"
flow. Note: the mock lives on `127.0.0.1`, so turning off Wi-Fi does **not** trigger this
branch (localhost is always reachable); `OFFLINE=1` simulates it properly with a dead port.

## What the mock does NOT do

It signs nothing real. If it finds a valid key (repo `.env` or `MOCK_LICENSE_KEY` env
var) it serves that, so a full end-to-end run works against the actual Gateway; otherwise
it mints fake tokens that pass the script's sanity check but that the Gateway would
reject. Real signing, real business-email validation, and the HubSpot write are the real
backend's job; they already exist internally (see the spec's scope note).

## For the backend (Matt)

Read the spec's §0 (Who builds what) and §6 (TL;DR), then use `mock-license-api/server.py`
as a behavioral reference for the endpoint. The open decisions that need your input are
listed in §4.
