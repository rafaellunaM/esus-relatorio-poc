# Teste isolado A: reproduz so a variavel "ps falso", com caminho raso (/tmp/pginstall)
# e cwd simples (/tmp), exatamente como o teste isolado anterior que funcionou -
# mudando so o fato de existir um /usr/local/bin/ps na frente do PATH que responde
# "systemd" para "ps --no-headers -o comm 1".
#
# Se este teste FALHAR com "invalid command line", confirma que o ps falso e a causa.
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

COPY postgresql-9.6.13-1-linux-x64.run /tmp/pginstall/postgresql-9.6.13-1-linux-x64.run

WORKDIR /tmp/pginstall

RUN chmod +x ./postgresql-9.6.13-1-linux-x64.run \
    && ( ./postgresql-9.6.13-1-linux-x64.run --create_shortcuts 0 --mode unattended \
         --unattendedmodeui none --superaccount postgres --superpassword "esus" \
         --serverport 5433 --servicename e-SUS-AB-PostgreSQL \
         --prefix "/tmp/pginstall/pg" \
         --datadir "/tmp/pginstall/pg/data" ; echo "EXIT CODE: $?" ) \
    && echo "--- procurando logs do bitrock ---" \
    && find / -xdev -iname "bitrock_installer.log" 2>/dev/null \
    && for f in $(find / -xdev -iname "bitrock_installer.log" 2>/dev/null); do \
         echo "=== $f ==="; cat "$f"; \
       done
