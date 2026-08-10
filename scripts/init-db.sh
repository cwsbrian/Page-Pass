#!/bin/sh
set -eu

test_database="${POSTGRES_DB}_test"

psql \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=ON_ERROR_STOP=1 \
  --set=test_database="$test_database" \
  --set=database_owner="$POSTGRES_USER" <<'SQL'
SELECT format(
  'CREATE DATABASE %I OWNER %I',
  :'test_database',
  :'database_owner'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = :'test_database'
)
\gexec
SQL
