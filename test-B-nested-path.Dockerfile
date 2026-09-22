# Teste isolado B: reproduz as variaveis "caminho aninhado real" + "cwd real"
# (/opt/e-SUS/tmp/database), SEM o ps falso, pra isolar dessas duas outra causa
# possivel. Cria a estrutura de diretorios /opt/e-SUS/* do jeito que o instalador
# real cria (so a parte relevante pro Postgres) antes de rodar o .run.
#
# Se este teste tambem FALHAR com "invalid command line", a causa e caminho/cwd
# (ou efeito cumulativo), nao o ps falso isoladamente.
# Se este teste PASSAR, e o teste A falhar, confirma que o ps falso e o culpado.
FROM mirror.gcr.io/library/eclipse-temurin:17-jdk-jammy

RUN apt-get update && apt-get install -y --no-install-recommends procps sudo file \
    && rm -rf /var/lib/apt/lists/*

# Sem ps falso aqui - fica o /usr/bin/ps real do pacote procps.

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
