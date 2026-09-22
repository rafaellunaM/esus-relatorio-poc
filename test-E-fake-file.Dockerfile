# Teste isolado E: em vez de criar um /sbin/init de verdade (que faz o BitRock
# do Postgres embutido erroneamente detectar systemd so pela existencia do
# arquivo, como provado pelos testes C e D), interceptamos o comando "file -L
# /sbin/init" (exatamente como ja interceptamos "ps --no-headers -o comm 1")
# para satisfazer soh a checagem de x64 do eSUS, sem nunca criar /sbin/init.
FROM mirror.gcr.io/library/eclipse-temurin:17-jdk-jammy

RUN apt-get update && apt-get install -y --no-install-recommends procps sudo file \
    && rm -rf /var/lib/apt/lists/*

RUN printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$*" = "--no-headers -o comm 1" ]; then' \
    '    echo systemd' \
    'else' \
    '    exec /usr/bin/ps "$@"' \
    'fi' \
    > /usr/local/bin/ps && chmod +x /usr/local/bin/ps

RUN printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$*" = "-L /sbin/init" ]; then' \
    '    echo "/sbin/init: ELF 64-bit LSB executable, x86-64, version 1 (SYSV)"' \
    'else' \
    '    exec /usr/bin/file "$@"' \
    'fi' \
    > /usr/local/bin/file && chmod +x /usr/local/bin/file

# Nao criamos /sbin/init - sua mera existencia (symlink ou copia real, testes
# C e D) ja faz o instalador do Postgres detectar "systemd" erroneamente.

RUN mkdir -p /opt/e-SUS/tmp/database \
    && mkdir -p "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64"

COPY postgresql-9.6.13-1-linux-x64.run /opt/e-SUS/tmp/database/postgresql-9.6.13-1-linux-x64.run

WORKDIR /opt/e-SUS/tmp/database

RUN chmod +x ./postgresql-9.6.13-1-linux-x64.run \
    && ( ./postgresql-9.6.13-1-linux-x64.run --create_shortcuts 0 --mode unattended \
         --unattendedmodeui none --superaccount postgres --superpassword "esus" \
         --serverport 5433 --servicename e-SUS-AB-PostgreSQL \
         --prefix "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64" \
         --datadir "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64/data" ; echo "EXIT CODE: $?" ) \
    && echo "--- procurando logs do bitrock ---" \
    && find / -xdev -iname "bitrock_installer.log" 2>/dev/null \
    && for f in $(find / -xdev -iname "bitrock_installer.log" 2>/dev/null); do \
         echo "=== $f ==="; cat "$f"; \
       done \
    && echo "--- checagem do eSUS (file -L /sbin/init) ---" \
    && file -L /sbin/init
