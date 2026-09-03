# Web Push notifications — implementation spec

Status: **specification only. Nothing in this document has been built.**

This is a build order for an implementer with write access to the repository,
Supabase and Vercel. It describes what to build, the conventions it must follow,
and how to prove it works.

## Why this is small

The receiving half already exists and does not need to be written:

- `manifest.webmanifest` is a valid installable PWA (`display: standalone`,
  maskable 192/512 icons) and is linked from `index.html:25`.
- `service-worker.js` is registered at `index.html:18698` and already handles
  `push` (line 61), calls `showNotification` (line 80), and handles
  `notificationclick` (line 83) including focusing an existing tab.

**Do not rewrite the service worker's push handling.** Match the payload it
already accepts:

```json
{
  "title": "string, defaults to 'LineCrew Pro'",
  "body": "string",
  "tag": "string, optional — collapses duplicate notifications",
  "renotify": false,
  "url": "/path to open on click, defaults to /",
  "data": { "any": "extra fields, merged into notification.data" }
}
```

What is missing is the *sending* half: permission and subscription on the
client, storage for subscriptions, and a function that delivers.

## Sequencing — build Phase 1 first and stop

**Phase 1 (build now):** subscription plumbing plus a "Send test notification"
button. This is provable today on a real phone.

**Phase 2 (build after Phase 1 is verified on iOS and Android):** the real
triggers — an unapproved Daily Report, a failed packet import, a weekly owner
digest.

The reason for the split is that `daily_reports` currently has **zero rows in
production**. A trigger written against it cannot be tested, so building Phase 2
first produces code nobody can verify. The test button proves the transport
independently of any workflow.

## Step 0 — VAPID keys (do this first, outside the repository)

```bash
npx web-push generate-vapid-keys
```

| Key | Where it goes | Notes |
|---|---|---|
| Public | Committed in `index.html` as a constant | Public by design — the browser needs it |
| Private | Supabase → Edge Functions → Secrets, as `VAPID_PRIVATE_KEY` | **Never** in the repository, a migration, a log line, or a chat message |
| Subject | Same secrets store, as `VAPID_SUBJECT` | `mailto:` address, e.g. `mailto:support@linecrewpro.com` |

Also add `PUSH_CRON_SECRET` (a long random string) to the same secrets store.
This follows the existing `CREW_USAGE_CRON_SECRET` pattern used by
`capture-crew-usage`.

Rotating VAPID keys invalidates every existing subscription, so treat the
private key as permanent once devices have subscribed.

## Step 1 — Migration

New file `supabase/migrations/<timestamp>_push_subscriptions.sql`. It must
follow the conventions every other table in this database follows: RLS enabled,
**all grants revoked**, access only through `SECURITY DEFINER` functions that
set an empty `search_path`.

```sql
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- The endpoint is the device address and is globally unique. A device that
  -- re-subscribes returns the same endpoint, so this is the conflict target.
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  failure_count integer not null default 0,
  constraint push_subscriptions_endpoint_unique unique (endpoint)
);

alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from public, anon, authenticated;

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);
create index if not exists push_subscriptions_company_idx
  on public.push_subscriptions (company_id);
```

Three RPCs, each `security definer`, `set search_path to ''`, revoked from
`public, anon` and granted to `authenticated` only:

**`linecrew_save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)`**
returns `void`. Resolves `company_id` from the caller's active profile; raises
if there is none. Upserts on `endpoint`, and on conflict reassigns `user_id`,
`company_id`, the keys and `user_agent`, and resets `failure_count` to 0. The
reassignment matters: a shared tablet can move between users, and the
subscription must follow the person now signed in.

**`linecrew_delete_push_subscription(p_endpoint text)`** returns `void`. Deletes
only where `user_id = auth.uid()` — a user may never delete another's device.

**`linecrew_my_push_status()`** returns `table(subscription_count integer)`.
Counts the caller's own rows. Used to render honest status in the UI.

Foreign keys need indexes; see the existing
`index_packet_unit_alias_foreign_keys` migration for the house style.

## Step 2 — Edge Function `send-push-notification`

New directory `supabase/functions/send-push-notification/`. Copy the structure
of `parse-utility-job-packet/index.ts`: the same CORS allowlist built from
`CORS_ALLOWED_ORIGINS`, the same structured `console.log(JSON.stringify({...}))`
logging, the same shape of error responses.

It reads `push_subscriptions` with the **service role key**, which bypasses RLS.
That is why the table has no policies — this function is the only reader.

### Two call modes, two different authorisations

**`mode: "test"`** — called from the browser with the user's JWT in the
`Authorization` header. Resolve the caller with a Supabase client created from
that header, then send **only to that caller's own subscriptions**. Never accept
a target user id in this mode.

**`mode: "notify"`** — called by `pg_cron` or another server process. Requires
header `x-push-cron-secret` matching `PUSH_CRON_SECRET`; reject with 401
otherwise. Accepts `{ user_ids: uuid[], title, body, url, tag }`.

### Delivery

Use `npm:web-push@3.6.7` via Deno's npm specifier. **Verify this imports and
signs correctly in the Supabase Edge Runtime before building anything on top of
it** — it depends on Node crypto APIs and is the single largest technical risk
in this spec. If it does not work, implement VAPID JWT signing plus `aes128gcm`
payload encryption with the Web Crypto API directly, or substitute a
Deno-native push library. Do not proceed on the assumption that the npm import
works.

### Dead subscription cleanup — required, not optional

A push endpoint returning **404** or **410 Gone** means the device has
permanently unsubscribed. Delete that row immediately. Without this the table
accumulates dead endpoints forever and every send gets slower.

On any other failure, increment `failure_count`; delete rows once
`failure_count` exceeds 10. On success set `last_success_at` and reset
`failure_count` to 0.

### Never put customer or personal data in a notification body

Notifications render on a **locked phone screen**, visible to anyone holding it.

- Good: `"A Daily Report is waiting for approval"`, `url: "/#reports"`
- Bad: anything naming a customer, a dollar amount, an address, or a utility

Put identifiers in `data`, not in `body`, and let the app show detail after the
user opens it.

## Step 3 — Client changes in `index.html`

Add a **Notifications** panel to the profile/settings area.

**State detection, in this order:**

1. `!('serviceWorker' in navigator) || !('PushManager' in window)` →
   "Not supported on this browser."
2. **iOS not installed** — `/iPad|iPhone|iPod/.test(navigator.userAgent)` and
   `!window.navigator.standalone` → show *"On iPhone, add LineCrew Pro to your
   Home Screen first: Share → Add to Home Screen."* and hide the enable button.
   This is the single biggest source of silent failure; see the caveat below.
3. `Notification.permission === 'denied'` → "Blocked in browser settings" with
   instructions, since the prompt cannot be shown again.
4. Otherwise show **Enable notifications**.

**Enable flow:**

```js
const permission = await Notification.requestPermission();
if (permission !== 'granted') { /* render the refused state, do not throw */ }
const registration = await navigator.serviceWorker.ready;
const subscription = await registration.pushManager.subscribe({
  userVisibleOnly: true,                     // required by Chrome; do not omit
  applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY)
});
const json = subscription.toJSON();
await sb.rpc('linecrew_save_push_subscription', {
  p_endpoint: subscription.endpoint,
  p_p256dh: json.keys.p256dh,
  p_auth: json.keys.auth,
  p_user_agent: navigator.userAgent.slice(0, 300)
});
```

`urlBase64ToUint8Array` is the standard helper — the VAPID public key is
base64url and `applicationServerKey` requires a `Uint8Array`.

**Also required:**

- A **Send test notification** button calling the Edge Function with
  `mode: "test"`.
- A **Disable** button: `subscription.unsubscribe()` then
  `linecrew_delete_push_subscription`.
- **Honest status text** driven by `linecrew_my_push_status()` — "On for this
  device" vs "Off". A user who believes notifications are on when they are not
  is the failure this whole feature must avoid, and it is exactly the class of
  silent failure that produced four dead-button bugs on 2026-09-02.
- Wrap the whole flow in `try`/`catch`. An uncaught rejection here now raises
  the global error banner added in #405, which is correct but not a good first
  experience.

## The iOS caveat — state it plainly to users

Web Push on iOS works **only when the site has been added to the Home Screen**.
In a normal Safari tab there is no push, and it fails silently. Android and
desktop Chrome need no install.

Verify current Safari behaviour on a real iPhone before promising this to a
customer; it has changed across iOS releases. Do not rely on documentation
alone.

Because of this, **email remains the backstop** for anything that genuinely
matters. Push is the fast path, not the guaranteed one.

## Step 4 — Deployment

Both halves deploy automatically on merge to `main`, with no manual step:

- `index.html` → Vercel.
- `supabase/functions/**` → the `deploy-edge-functions.yml` workflow.

**The migration does not deploy itself.** Apply it through the migration runner,
not the SQL Editor — applying it by hand is what produced the drift that
required the 2026-09-02 baseline. See `internal-docs/MIGRATION_BASELINE.md`.

Bump `CACHE_NAME` in `service-worker.js` (currently `linecrew-pro-shell-v56`) so
clients pick up the new shell.

## Verification

Repository:

1. `node scripts/validate-app.mjs`
2. `node scripts/validate-production-readiness.mjs`
3. `node supabase/functions/parse-utility-job-packet/packet-logic.test.mjs`
4. Add a `validate-app.mjs` assertion that the subscribe flow passes
   `userVisibleOnly: true` and that the disable path calls both `unsubscribe()`
   and the delete RPC.

Live, in this order:

5. **Android/Chrome**: enable, confirm a row appears in `push_subscriptions`,
   send a test, confirm it arrives with the app closed.
6. **iPhone**: confirm the "Add to Home Screen" message appears in a normal
   Safari tab; then install, enable, and confirm a test notification arrives.
7. Tap a notification and confirm `notificationclick` focuses or opens the app
   at the `url` from the payload.
8. Disable, and confirm the row is deleted.
9. Simulate a dead endpoint (subscribe, then clear the site data without
   disabling) and confirm the 404/410 path deletes the row rather than
   retrying forever.
10. Supabase advisors: no new ERROR-level findings.

## Phase 2 triggers, once Phase 1 is verified

Schedule with `pg_cron`, following the existing `linecrew-daily-crew-usage` job,
calling the function with `mode: "notify"` and the cron secret.

| Trigger | Audience | Body (no PII) |
|---|---|---|
| Daily Report submitted and unapproved > 48h | GF / Admin | "A Daily Report is waiting for approval" |
| Packet import failed | the uploader | "A job packet could not be read" |
| Weekly summary, Monday | Owner / Admin | "Last week's production summary is ready" |

Each needs a query that identifies target `user_ids`, and each must be
idempotent — a cron that fires hourly must not re-notify about the same report
every hour. Record what was sent, or use `tag` so the device collapses repeats.
