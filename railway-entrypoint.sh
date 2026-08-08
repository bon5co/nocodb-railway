#!/bin/sh
# NocoDB on Railway: close the instance BEFORE the public port ever answers.
#
# Two upstream behaviours make a stock deploy claimable by a stranger:
#
#   1. The first account ever created gets `roles: super`. `POST
#      /api/v1/auth/user/signup` is unauthenticated, so whoever reaches the
#      Railway URL first owns the instance — measured on nocodb 2026.07.0 as an
#      anonymous signup returning a JWT with `"roles":"org-level-creator,super"`.
#   2. `invite_only_signup` defaults to false and lives in the meta database,
#      not in any environment variable, so even once an admin exists every
#      stranger can still create an org-level account on the deployer's box.
#
# NC_ADMIN_EMAIL / NC_ADMIN_PASSWORD fix (1) — but only if the seeded admin
# exists before the first request. Flipping (2) needs an authenticated call to
# `POST /api/v1/app-settings`, i.e. the server has to be up. Doing that after
# the public listener binds leaves exactly the window this is meant to close
# (the AzuraCast lesson: seeding after start is not seeding).
#
# So on first boot we start NocoDB on a loopback-only port, wait for it, seed
# the admin session, flip invite_only_signup, stop it, and only then start the
# real listener on $PORT. Later boots skip straight to the real listener.
set -e

: "${NC_ADMIN_EMAIL:?[railway] NC_ADMIN_EMAIL is required}"
if [ -z "${NC_ADMIN_PASSWORD:-}" ]; then
    echo "[railway] NC_ADMIN_PASSWORD is empty — refusing to boot an instance anyone could claim" >&2
    exit 1
fi

DATA_DIR="${NC_TOOL_DIR:-/usr/app/data/}"
MARKER="${DATA_DIR%/}/.railway-bootstrapped"
BOOTSTRAP_PORT=8090
REAL_PORT="${PORT:-8080}"

mkdir -p "${DATA_DIR%/}"

api() {
    curl -sS -o /tmp/nc-api.out -w '%{http_code}' "$@"
}

bootstrap() {
    echo "[railway] first boot: bootstrapping on 127.0.0.1:${BOOTSTRAP_PORT} before opening ${REAL_PORT}"

    PORT="$BOOTSTRAP_PORT" /usr/src/appEntry/start.sh &
    boot_pid=$!

    i=0
    while [ "$i" -lt 120 ]; do
        if curl -sf "http://127.0.0.1:${BOOTSTRAP_PORT}/api/v1/health" >/dev/null 2>&1; then
            break
        fi
        kill -0 "$boot_pid" 2>/dev/null || { echo "[railway] bootstrap instance died" >&2; exit 1; }
        i=$((i + 1))
        sleep 2
    done
    if [ "$i" -ge 120 ]; then
        echo "[railway] bootstrap instance never became healthy" >&2
        exit 1
    fi

    code=$(api -X POST "http://127.0.0.1:${BOOTSTRAP_PORT}/api/v1/auth/user/signin" \
        -H 'Content-Type: application/json' \
        --data-binary "$(printf '{"email":"%s","password":"%s"}' "$NC_ADMIN_EMAIL" "$NC_ADMIN_PASSWORD")")
    if [ "$code" != "200" ]; then
        echo "[railway] could not sign in as the seeded admin (HTTP $code)" >&2
        cat /tmp/nc-api.out >&2 || true
        exit 1
    fi
    token=$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).token||""))' </tmp/nc-api.out)
    [ -n "$token" ] || { echo "[railway] admin signin returned no token" >&2; exit 1; }

    code=$(api -X POST "http://127.0.0.1:${BOOTSTRAP_PORT}/api/v1/app-settings" \
        -H "xc-auth: $token" -H 'Content-Type: application/json' \
        --data-binary '{"invite_only_signup":true}')
    if [ "$code" != "200" ]; then
        echo "[railway] could not close public signup (HTTP $code)" >&2
        cat /tmp/nc-api.out >&2 || true
        exit 1
    fi

    code=$(api "http://127.0.0.1:${BOOTSTRAP_PORT}/api/v1/app-settings" -H "xc-auth: $token")
    echo "[railway] app settings after bootstrap: $(cat /tmp/nc-api.out)"
    grep -q '"invite_only_signup":true' /tmp/nc-api.out || {
        echo "[railway] invite_only_signup did not stick" >&2; exit 1; }

    kill "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true

    : >"$MARKER"
    echo "[railway] bootstrap complete: admin seeded, public signup closed"
}

if [ ! -f "$MARKER" ]; then
    bootstrap
else
    echo "[railway] already bootstrapped, starting normally"
fi

export PORT="$REAL_PORT"
exec /usr/src/appEntry/start.sh
