#!/usr/bin/env bash
set -euo pipefail

test_id="${GITHUB_RUN_ID:-local}-$$"
source_container="linecrew-restore-source-${test_id}"
target_container="linecrew-restore-target-${test_id}"
work_dir="$(mktemp -d)"

cleanup() {
  docker rm -f "$source_container" "$target_container" >/dev/null 2>&1 || true
  rm -rf "$work_dir"
}
trap cleanup EXIT

start_postgres() {
  local container="$1"
  docker run --detach --name "$container" \
    --env POSTGRES_PASSWORD=linecrew-restore-test \
    --env POSTGRES_DB=linecrew \
    postgres:17-alpine >/dev/null
  for _ in $(seq 1 60); do
    if docker exec "$container" pg_isready --username postgres --dbname linecrew >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "PostgreSQL container did not become ready: $container" >&2
  exit 1
}

start_postgres "$source_container"
start_postgres "$target_container"

docker exec --interactive "$source_container" psql --username postgres --dbname linecrew --set ON_ERROR_STOP=1 <<'SQL'
create role anon noinherit;
create role authenticated noinherit;
create role authenticator noinherit;
create or replace function public.enforce_linecrew_company_access()
returns void language plpgsql security definer as $ begin return; end; $;
revoke all on function public.enforce_linecrew_company_access() from public, anon, authenticated;
grant execute on function public.enforce_linecrew_company_access() to authenticator;
alter role authenticator set pgrst.db_pre_request = 'public.enforce_linecrew_company_access';
SQL

docker exec "$source_container" pg_dump \
  --username postgres --dbname linecrew --format custom --no-owner \
  --schema public --file /tmp/linecrew-security-test.dump
docker cp "$source_container:/tmp/linecrew-security-test.dump" "$work_dir/linecrew-security-test.dump" >/dev/null

docker exec "$target_container" psql --username postgres --dbname linecrew --set ON_ERROR_STOP=1 \
  --command 'create role anon noinherit; create role authenticated noinherit; create role authenticator noinherit; drop schema public cascade;'
docker cp "$work_dir/linecrew-security-test.dump" "$target_container:/tmp/linecrew-security-test.dump" >/dev/null
docker exec "$target_container" pg_restore \
  --username postgres --dbname linecrew --no-owner \
  /tmp/linecrew-security-test.dump

if docker exec "$target_container" psql --username postgres --dbname linecrew --tuples-only --no-align \
  --command "select 1 from pg_db_role_setting s join pg_roles r on r.oid=s.setrole where r.rolname='authenticator' and 'pgrst.db_pre_request=public.enforce_linecrew_company_access'=any(s.setconfig);" | grep -q '^1$'; then
  echo 'SECURITY TEST FAILURE: pg_restore unexpectedly preserved the role setting.' >&2
  exit 1
fi

docker cp scripts/post-restore-security.sql "$target_container:/tmp/post-restore-security.sql" >/dev/null
docker cp scripts/verify-post-restore-security.sql "$target_container:/tmp/verify-post-restore-security.sql" >/dev/null
docker exec "$target_container" psql --username postgres --dbname linecrew \
  --file /tmp/post-restore-security.sql
docker exec "$target_container" psql --username postgres --dbname linecrew \
  --file /tmp/verify-post-restore-security.sql

echo 'PASS: pg_restore omitted the global gate, and the recovery bootstrap restored and verified it.'
