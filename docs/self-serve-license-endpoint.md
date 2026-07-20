# Gateway CE Self-Serve License Endpoint

Let the CE quickstart install script (`start.sh`, in the `gateway-community-quickstart`
repo) get a license without leaving the terminal. Today the flow is fully manual: the
user requests a key on the website and pastes it into the script. Self-serve automates
that: **email in, license out, CRM record stamped.**

> **Scope note:** a license-issuing service already exists (the manual flow issues valid
> licenses today), and so does the internal business-email validator. This endpoint
> **wraps what exists**; it does not reinvent JWT signing or email rules. Matt's real
> work is an HTTP endpoint in front of those two, plus the CRM write. The rest is bells
> and whistles.

> **Play with it:** a runnable mock of this exact contract lives in
> [`mock-license-api/`](../mock-license-api/) on the `feat/self-serve-license` branch.
> Run `./mock-license-api/demo.sh` to experience the whole user flow in one command
> (business email -> license; personal email -> 403; every branch below is implemented).
> The refactored `start.sh` on that branch is the real client for it.

---

## 0. Who builds what

**Matt / the API** owns everything server-side. It never sees the terminal:

- The HTTP endpoint (`POST … -> { license }`).
- Email format and **business-email** validation (server-side).
- License JWT generation and signing with the Gateway's key.
- TTL / expiry logic.
- Idempotency per email.
- Rate limiting / throttling.
- CRM upsert and field stamping, **only on `200` success**. Needs **HubSpot write
  credentials** (a private-app token with contact write scope), a provisioning
  dependency that must exist before the CRM write works.
- Error responses with the distinct codes in §1.
- Logging / metrics of every outcome (issued vs. rejected plus reason), the only place
  rejections are visible (see §2).

**Ron / the install script** owns everything terminal-side. It never touches HubSpot or
signs anything:

- Connectivity probe (is the endpoint reachable?).
- Prompting the user for their email plus the `"Provisioning your license…"` messaging.
- Sending the POST and reading the response.
- Reacting to each status code as UX: re-prompt, **show the user a form link**, or drop
  to the manual paste fallback (see §5).
- A cheap client-side email format check (typo catch only, not enforcement).
- Offline / airgap manual-paste fallback (today's flow).
- JWT **sanity** and expiry check, and saving to `.env`. Note: the script **cannot verify
  the signature**; only the Gateway can. A well-formed but wrongly-signed token passes
  the script and fails at Gateway startup, so **the Gateway healthcheck is the ultimate
  validation** (the script already detects an unhealthy Gateway and surfaces license
  errors from its logs).
- Non-interactive env-var handling.

Rule of thumb: **the API decides and issues; the script asks and displays.**

---

## 0.5 Personas & the two ways a user gets a license

**Personas (runtime):**
- **User:** the developer running `start.sh`. Wants a license.
- **Script:** `start.sh`. Asks for the email, displays messages, saves the key.
- **API:** Matt's endpoint. Either issues a license or returns an error (bad email /
  throttled). Never involves a human.
- **Reviewer (SE):** a Conduktor human who triages **web-form** requests in HubSpot.

**Path A, Self-serve (automated, no human).** Requires: online **and** valid business
email.
```
User types email into script -> script POSTs to API -> API issues license
-> script saves to .env. Done, entirely in the terminal.
```

**Path B, Manual form (human-approved).** The fallback for every case where Path A
doesn't apply (offline/airgap, `403` denied, `429` rate-limited, `5xx`), **and** the
appeal path for a denial:
```
1. Script shows the User the web-form URL.
2. User fills the form (from any machine with internet) with their email.
3. Form creates the HubSpot contact and fires the existing Slack notification.
4. Reviewer (SE) approves and sends the User a key by email (or ignores / denies).
5. User pastes the received key into the script prompt.
6. Script validates it and saves to .env.
```

So **"fill the form" (step 2) and "paste the key" (step 5) are two steps of the same
path, never alternatives.** Paste is always the last step of Path B, after a human sent
a key. A `403` denial simply drops the User into Path B, where the Reviewer can override
the machine's decision.

---

## 1. Contract

**Request** (host and path below are placeholders; final URL is Matt's to pick)
```
POST /gateway/community-edition/license
Content-Type: application/json

{ "email": "user@company.com", "source": "gateway-ce-quickstart" }
```
Email is the only field collected.

**Success**
```
200 OK
{ "license": "<JWT>", "expires_at": "2026-12-31T00:00:00Z" }
```
`license` is a JWT signed with the key the Gateway validates against. `expires_at` is
optional (the script can read expiry from the JWT itself); it's handy for messaging.

**Errors**

| Status | error                   | Meaning                | Script does                          |
|--------|-------------------------|------------------------|--------------------------------------|
| `400`  | `invalid_email`         | Malformed              | Re-prompt for email                  |
| `403`  | `invalid_business_email`| Not a business email   | Show message, offer form link, re-prompt  |
| `429`  | `rate_limited`          | Too many requests      | Show message, offer the user to fill out form instead     |
| `5xx`  | (none)                  | Server error           | Fall back to user form          |
| timeout| (none)                  | Unreachable            | Fall back to user form           |

Body: `{ "error": "...", "message": "..." }`. `403` must be a **distinct code** so the
script can branch (it is not a paste-fallback case: internet works, the email was
rejected).

---

## 2. CRM (replaces manual SE stamping)

**Context (how it works today):** our CRM is **HubSpot**. When someone fills out the
license request form on the website, a HubSpot **contact** is created for that email, and
an SE then **manually** stamps a few fields on it (whether the license was sent, the
dates, the expiry). Self-serve replaces that manual step: when the API issues a license,
**it creates/updates the HubSpot contact and stamps those same fields automatically.**

**Only on a `200` success.** Any error (`400`/`403`/`429`/`5xx`) creates **no contact
and stamps nothing**; a rejected email never lands in HubSpot. This is what keeps junk
and invalid-business-email attempts out of the CRM.

A request is marked in two parts: **a status plus its matching date** (plus expiry if sent).

| Outcome  | Status            | Date              | Expiry      | Set by                                              |
|----------|-------------------|-------------------|-------------|-----------------------------------------------------|
| Issued   | `License Sent`    | Sent Date = today | today + TTL | **API**, Path A, on `200`                           |
| Rejected | `Request Ignored` | Denied Date       | (none)      | **Human reviewer**, only after the User fills the form (Path B) |

Plus `Source = self-serve` on the issued row.

**The API only ever writes the top row.** The bottom row (`Request Ignored` plus Denied
Date) only ever happens when the User has fallen back to **Path B and actually filled
out the form**, which creates a real contact for a human reviewer to mark. Self-serve
itself has no human and never marks a denial: a self-serve rejection writes **nothing at
all** (no contact, no status). No form fill, no `Request Ignored` row, ever.

> The script caps email entry at **3 attempts** as a UX guard, then sends the User to
> Path B. It does **not** auto-mark a denial: there's no valid contact to attach it to,
> the API is stateless (it can't count attempts), and a reload resets the counter, so an
> auto-denial would be meaningless. Repeat abuse is handled by API throttling (§4), which
> survives reloads; denials stay a human call on Path B.

No Slack notification (self-serve is auto-issued; nothing to action). `Source` is
stamped so a HubSpot workflow can be added later with zero backend change.

**Rejections are not in the CRM, by design.** A rejected email (bad business email,
malformed, rate-limited) creates no contact, so HubSpot stays clean. Visibility into
rejections comes from the **API's own logs/metrics** (issued vs. rejected plus reason),
so "how do we know someone got rejected?" means monitor the API, not HubSpot. (A real
prospect who typos or uses a personal email vanishes with no CRM trace; if we later want
to chase those near-misses, the API could push them to a separate "rejected" list, out
of scope for v1.)

---

## 3. Guarantees

- **Validates its own input.** Endpoint is public/unauthenticated, so assume raw `curl`,
  not the script. Business-email check runs server-side.
- **Idempotent per email = "one active license per user."** On success the API
  looks up the email's current license, returns the same one if it's still valid, and
  mints a fresh one only if none exists or it's expired. Upsert the contact either way
  (no duplicate contacts). This one rule covers three cases with no extra endpoint:
  - **Renewal:** expired, so mint fresh, same contact, updated dates.
  - **Lost/deleted `.env`:** no local key, so a re-run on the same email returns the
    **same key** (not a new one); re-entering the email 10x doesn't spawn 10 keys. The
    POST *is* the lookup; no separate "do you have a key?" endpoint.
  - **New user:** creates the contact plus first license.

  > **Question for Matt:** can the license service *return a user's existing active
  > license*, or only mint new ones? If it can't look one up, fall back to "always mint
  > fresh" and rely on **throttling** to cap repeat calls (harmless for free CE: same
  > contact, no seats, just untidier). Return-existing is preferred.

  Re-issuing need **not revoke** any prior license (JWTs stay valid until their own
  expiry, harmless for free CE).
- **Rate limited / throttled:** the abuse control (we chose instant issue, no email
  verification). Exact strategy is Matt's call, see §4.

---

## 4. Decisions

Locked:
- Fields: **email only.** Done.
- **Instant issue, no double opt-in.** Done.

Open, to discuss with Matt (API-side, his recommendation):
- **License TTL & renewal:** how long is a license valid, and what happens on expiry?
  Feeds the Expiry field plus the JWT's own expiry.
- **Throttling:** what rate-limit strategy (per-IP? per-domain? caps?) to stop farming?
  Assumed handled in the API; open on the specifics.

Open, to confirm elsewhere:
- **Consent:** the web form has consent language; the terminal has none. Legal/marketing
  to confirm CLI capture is OK or add a consent line.
- **Contact creation via API:** confirm HubSpot allows it (no form fill to create it).
- Email the license to the user as a backup copy, optional nice-to-have.

---

## 5. Script flow (context)

```
Have a key? (.env / env var)
├─ YES -> still valid (not expired)? script checks expiry
│         ├─ valid   -> use it                          (re-runs = no API call)
│         └─ expired -> treat as no key, re-provision   (renewal = just re-run)
└─ NO  (new user, OR deleted/lost .env) -> endpoint reachable? (~3s probe)
          ├─ NO  -> offline, Path B (manual form)                      (= today)
          └─ YES -> "Provisioning your license…", prompt email, POST
                    ├─ 200 -> Path A: save license to .env             done in terminal
                    │         (API returns your existing key if still valid,
                    │          else mints a fresh one, see §3)
                    ├─ 403 -> script tells User: "Please use a valid business email.
                    │          If you think this is a mistake, request one here: <form>"
                    │          re-prompt (up to 3 tries total), then Path B (appeal)
                    ├─ 400 -> script tells User "that email looks invalid"
                    │          re-prompt (up to 3 tries total), then Path B
                    └─ 429 / 5xx -> script points User to Path B (manual form)
```
The **3-attempt cap** is a script-side UX limit only; after the 3rd failed email the
script stops asking and points to Path B. It writes nothing to the CRM (see §2).

All quoted text is printed by the **script** to the User. `<form>` is the existing
website form (Path B, §0.5); the script only links to it, and the API is not involved
once the User leaves for Path B.

**Deleted / lost `.env`:** no special path, it's just "no key", so the script
re-provisions on the same email (Path A) or points to the form (Path B). The default is
**re-fetch from the API**, not "go find your old key." Anyone who kept a copy can still
paste it, but the script never makes them hunt for it.

Non-interactive: `GATEWAY_LICENSE_KEY=<key>` (paste) or `GATEWAY_LICENSE_EMAIL=<email>`
(headless self-serve).

**Ship order:** the airgap-safe script (manual fallback = today's code) ships now, with
no dependency on the endpoint. The self-serve branch turns on when the endpoint is live.

---

## 6. Backend TL;DR

`POST { email, source } -> { license }`. Sign the JWT with the Gateway's key. Idempotent
per email, rate-limited, validates business email server-side (distinct `403`). On
success, upsert the CRM contact and stamp License Sent, Sent Date, Expiry, and Source;
never touch deny/ignore; no Slack.
