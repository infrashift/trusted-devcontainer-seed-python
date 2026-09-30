#!/usr/bin/env bash
# First start only: initialise the data directory and run
# /docker-entrypoint-initdb.d/*.sql once, the way the official postgres image
# does. This image (Docker Hardened Images' postgres, via the InfraShift
# trusted line) ships a smaller entrypoint that creates the user and database
# but runs no init scripts.
#
# The scripts run inside the init window, with the server on its local socket
# only, so nothing can connect -- or pass a health check -- before the seed
# data exists. Each file is one transaction: a failure leaves no half-seeded
# schema, and the start fails loudly instead of serving an empty database.
#
# Every later start is the image's own entrypoint, untouched, which execs
# postgres as PID 1.
set -Eeuo pipefail

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  : "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_DB="${POSTGRES_DB:-$POSTGRES_USER}"

  initdb --username="$POSTGRES_USER" --pwfile=<(printf '%s\n' "$POSTGRES_PASSWORD")
  printf '\nhost all all all %s\n' "$(postgres -C password_encryption)" >> "$PGDATA/pg_hba.conf"

  pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start
  export PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"
  [ "$POSTGRES_DB" = postgres ] || createdb --no-password "$POSTGRES_DB"
  for f in /docker-entrypoint-initdb.d/*.sql; do
    [ -e "$f" ] || continue
    echo "seed-entrypoint: running $f"
    psql -v ON_ERROR_STOP=1 --no-password --single-transaction --dbname "$POSTGRES_DB" -f "$f"
  done
  unset PGUSER PGPASSWORD
  pg_ctl -D "$PGDATA" -m fast -w stop
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"
