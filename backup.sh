#!/usr/bin/env bash
# Encrypted PostgreSQL export -> off-site R2 sink. Needs: pg_dump 17, age, curl.
# Env: BACKUP_DATABASE_URL, BACKUP_ENV (prod|staging), AGE_RECIPIENT, INGEST_URL, INGEST_TOKEN, STATUS_TOKEN
set -euo pipefail
if [[ "${BACKUP_ENV:-}" == "prod" ]]; then BACKUP_DATABASE_URL="${PROD_DATABASE_URL:-}"; else BACKUP_DATABASE_URL="${STAGING_DATABASE_URL:-}"; fi
if [[ -z "$BACKUP_DATABASE_URL" ]]; then
  echo "::warning::No database URL secret for ${BACKUP_ENV:-?}; skipped. The off-site monitor reports the missing backup."
  exit 0
fi

umask 077

: "${BACKUP_DATABASE_URL:?}" "${BACKUP_ENV:?}" "${AGE_RECIPIENT:?}" "${INGEST_URL:?}" "${INGEST_TOKEN:?}" "${STATUS_TOKEN:?}"
[[ "$AGE_RECIPIENT" =~ ^age1[a-z0-9]+$ ]] || { echo "AGE_RECIPIENT must be an age public key"; exit 2; }
[[ "$BACKUP_ENV" =~ ^(prod|staging)$ ]] || { echo "BACKUP_ENV must be prod or staging"; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
key="v1/${BACKUP_ENV}/${stamp}.pgdump.age"

export PGSSLMODE=verify-full PGSSLROOTCERT="$PWD/supabase-root-2021.crt" PGCONNECT_TIMEOUT=20
pg_dump --dbname="$BACKUP_DATABASE_URL" --format=custom --compress=6 \
  --schema=auth --schema=public --schema=private --schema=supabase_migrations \
  --file="$work/dump.pgdump" 2>"$work/pg_dump.err" || { sed -E 's#(postgres(ql)?://)[^@ ]*@#\1***@#g' "$work/pg_dump.err" | tail -5; echo "pg_dump failed"; exit 1; }

entries="$(pg_restore --list "$work/dump.pgdump" | grep -c '^[0-9]')"
size="$(stat -c %s "$work/dump.pgdump")"
(( entries >= 500 && size >= 100000 )) || { echo "Dump implausibly small (entries=$entries bytes=$size)"; exit 1; }

age -r "$AGE_RECIPIENT" -o "$work/dump.pgdump.age" "$work/dump.pgdump"
sha="$(sha256sum "$work/dump.pgdump.age" | cut -d' ' -f1)"

code="$(curl -sS -o "$work/put.out" -w '%{http_code}' --retry 3 --retry-all-errors --max-time 120 \
  -X PUT "${INGEST_URL%/}/${key}" \
  -H "authorization: Bearer ${INGEST_TOKEN}" -H "x-content-sha256: ${sha}" \
  --data-binary "@$work/dump.pgdump.age")"
[[ "$code" == "201" ]] || { echo "Upload rejected: HTTP $code $(cat "$work/put.out")"; exit 1; }

latest="$(curl -sS --max-time 30 -H "authorization: Bearer ${STATUS_TOKEN}" "${INGEST_URL%/}/v1/${BACKUP_ENV}/status")"
grep -q "\"key\":\"${key}\"" <<<"$latest" || { echo "Uploaded object not listed as newest"; exit 1; }
echo "backup ok env=${BACKUP_ENV} key=${key} entries=${entries} dump_bytes=${size} cipher_sha256=${sha}"
