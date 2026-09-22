# Teste isolado C: combina as duas variaveis dos testes A e B ao mesmo tempo -
# caminho aninhado real (/opt/e-SUS/...) + cwd real (/opt/e-SUS/tmp/database) + ps
# falso simulando systemd. Ainda sem rodar o instalador Java completo.
#
# A e B passaram isoladamente. Se C tambem passar, a causa do bug real esta em
# outra coisa especifica do processo Java do instalador (env vars, permissoes
# deixadas pela etapa do JRE, estado em /tmp, etc.), nao nessas 3 variaveis.
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

RUN test -e /sbin/init || ln -s /bin/bash /sbin/init

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
       done
