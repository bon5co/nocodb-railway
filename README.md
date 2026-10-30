# nocodb-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/nocodb-202608-or-airtable-alternative-no?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [NocoDB template](https://railway.com/deploy/nocodb-202608-or-airtable-alternative-no?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

Wrapper image for the Railway template **NocoDB | Airtable Alternative Nobody Else Can Claim**.

`FROM nocodb/nocodb:2026.08.0` plus one entrypoint that closes the instance before the public
port ever answers.

## Why

Two upstream behaviours make a stock NocoDB deploy claimable by whoever reaches the URL first:

1. `POST /api/v1/auth/user/signup` is unauthenticated and the **first** account ever created is
   given `roles: super`. Measured on `nocodb/nocodb:2026.07.0` (the tag the category leader
   pins): an anonymous signup against a fresh instance returns a JWT carrying
   `"roles":"org-level-creator,super"`, and `GET /api/v1/auth/user/me` confirms
   `{"org-level-creator":true,"super":true}`.
2. `invite_only_signup` defaults to `false` and lives in the **meta database**, not in any
   environment variable. So even once a super admin exists, every stranger can still create an
   org-level account: measured as anonymous signup `200` with `org-level-viewer` on an instance
   that already had a seeded admin.

`NC_ADMIN_EMAIL` / `NC_ADMIN_PASSWORD` fixes (1) only if the admin exists before the first
request. Fixing (2) needs an authenticated `POST /api/v1/app-settings`, which requires a running
server — and doing that after the public listener binds leaves open exactly the window it is
meant to close.

## What the entrypoint does

On first boot only (marker file on the volume):

1. starts NocoDB on `127.0.0.1:8090`, not on `$PORT`;
2. waits for `/api/v1/health`;
3. signs in as the seeded `NC_ADMIN_EMAIL` (fails the boot if that does not work);
4. `POST /api/v1/app-settings {"invite_only_signup": true}` and reads the value back;
5. stops the bootstrap instance and only then starts the real listener on `$PORT`.

It refuses to boot on an empty `NC_ADMIN_PASSWORD`.

Verified locally against a fresh Postgres, on `2026.08.0`:

| check | stock | this image |
|---|---|---|
| anonymous `POST /auth/user/signup` | `200`, role `super` | `400 Not allowed to signup, contact super admin.` |
| seeded admin signin | n/a | `200` |
| wrong password | n/a | `400` |
| empty `NC_ADMIN_PASSWORD` | boots | refuses to boot |
| anonymous signup after a redeploy | `200` (still open) | `400` |
