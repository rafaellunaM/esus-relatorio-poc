#!/bin/bash
set -e

PG_ROOT="/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64"
PG_DATA="$PG_ROOT/data"
PG_CTL="$PG_ROOT/bin/pg_ctl"
PG_LOG="/opt/e-SUS/database/postgres.log"
INIT_SCRIPT="/etc/init.d/e-SUS-AB-PostgreSQL"

start_postgres() {
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" start
        return
    fi

    if [ ! -x "$PG_CTL" ]; then
        echo "Nao encontrei o PostgreSQL embutido em $PG_ROOT" >&2
        exit 1
    fi

    if id postgres >/dev/null 2>&1; then
        chown -R postgres:postgres "$PG_ROOT"
        su postgres -c "$PG_CTL -D '$PG_DATA' -l '$PG_LOG' -w start"
    else
        "$PG_CTL" -D "$PG_DATA" -l "$PG_LOG" -w start
    fi
}

start_postgres

exec /opt/e-SUS/webserver/standalone.sh -b 0.0.0.0
