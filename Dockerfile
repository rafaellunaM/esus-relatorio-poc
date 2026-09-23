# O eSUS-AB-PEC-*.jar nao e uma aplicacao pronta: e o instalador oficial do
# e-SUS AB PEC, que empacota um JRE, um PostgreSQL 9.6 proprio e o app real
# (pec-bundle.jar) e instala tudo em /opt/e-SUS. Por isso o build tem 2 estagios:
# 1) roda o instalador em modo console/nao-interativo para gerar /opt/e-SUS
# 2) copia so o resultado para uma imagem final enxuta

# Usamos mirror.gcr.io (mirror publico do Docker Hub) em vez de "eclipse-temurin:..."
# direto, so para este projeto: a config global do container runtime redireciona
# docker.io para um proxy interno que nao enxergamos aqui. Apontando para um host
# diferente de docker.io, o build ignora esse redirecionamento sem precisar
# mexer na config global do builder.
#
# JDK 8, nao 17: o e-SUS AB PEC (JBoss AS 7.2 + Liquibase antigo) e uma
# aplicacao da era pre-Java-9. Rodando o instalador com JDK 17 o encapsulamento
# forte de modulos (padrao desde o JDK 16) e a remocao de APIs como
# javax.xml.bind quebram reflection que o Liquibase/Hibernate antigos usam
# pra rodar as migrations do schema do e-SUS -- e e exatamente isso que causa
# falha no meio do MigratorRunner durante a instalacao. jammy continua sendo
# Ubuntu 22.04; so a major version do JDK muda aqui.
FROM mirror.gcr.io/library/eclipse-temurin:8-jdk-jammy AS installer

RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    sudo \
    file \
    locales \
    && rm -rf /var/lib/apt/lists/*

# O eSUS grava lc_messages/lc_monetary/lc_numeric/lc_time = pt_BR.UTF-8 no
# postgresql.conf de forma fixa quando roda em Unix, mas essa imagem base nao
# tem locales geradas por padrao. Sem isso o Postgres recusa iniciar com
# "invalid value for parameter ... FATAL: configuration file ... contains
# errors".
RUN sed -i 's/^# *pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen pt_BR.UTF-8

# O instalador do PostgreSQL 9.6 embutido (EnterpriseDB/BitRock) roda um
# script de pos-instalacao com bashismos, mas invoca via /bin/sh. No Ubuntu
# /bin/sh e o dash, que nao entende essa sintaxe e falha com "Problem running
# post-install step... invalid command line". Trocamos /bin/sh por bash so
# neste estagio de build.
RUN ln -sf bash /bin/sh

# A checagem de arquitetura do eSUS roda "file -L /sbin/init" e olha se a
# saida contem "64-bit". Essa imagem base nao tem /sbin/init. Criar um
# /sbin/init de verdade (symlink ou copia) pra passar nessa checagem tem um
# efeito colateral grave: o instalador do PostgreSQL embutido (BitRock) usa a
# mera EXISTENCIA de /sbin/init (independente do conteudo) como heuristica pra
# concluir que o sistema roda systemd, e tenta "systemctl start ...", que nao
# existe no container - causando "Problem running post-install step... invalid
# command line" na instalacao do Postgres (bug isolado e confirmado com testes
# isolados: ver historico de STATUS.md). Por isso interceptamos so a chamada
# "file -L /sbin/init" com um "file" falso, sem nunca criar /sbin/init.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$*" = "-L /sbin/init" ]; then' \
    '    echo "/sbin/init: ELF 64-bit LSB executable, x86-64, version 1 (SYSV)"' \
    'else' \
    '    exec /usr/bin/file "$@"' \
    'fi' \
    > /usr/local/bin/file && chmod +x /usr/local/bin/file

COPY eSUS-AB-PEC-5.5.28-Linux64.jar /tmp/installer.jar

# WORKDIR explicito: sem isso, o cwd do processo Java as vezes fica
# vazio nesse ambiente de build, e o instalador falha ao tentar rodar
# "/bin/sh -c id -u" com erro "Cannot run program... (in directory \"\")"
WORKDIR /tmp

# O instalador recusa instalar se "ps --no-headers -o comm 1" nao
# devolver "systemd" (checagem de que a distro usa systemd como init).
# Dentro de um container de build isso nunca vai ser verdade e nao importa
# pra gente (o entrypoint.sh final nao depende de systemd). Interceptamos
# so essa chamada especifica com um "ps" falso em /usr/local/bin, que tem
# prioridade no PATH sobre o /usr/bin/ps de verdade; qualquer outro uso de
# "ps" continua caindo no binario real.
RUN printf '%s\n' \
    '#!/bin/sh' \
    'if [ "$*" = "--no-headers -o comm 1" ]; then' \
    '    echo systemd' \
    'else' \
    '    exec /usr/bin/ps "$@"' \
    'fi' \
    > /usr/local/bin/ps && chmod +x /usr/local/bin/ps

# O instalador spawna subprocessos Java (ex.: MigratorRunner, que roda as
# migrations Liquibase do schema do e-SUS) sem heap explicito. O default
# ergonomico da JVM (baseado na memoria do container) e insuficiente pro
# volume de migrations do e-SUS e derruba com "OutOfMemoryError: Java heap
# space". JAVA_TOOL_OPTIONS e lido por qualquer JVM filha automaticamente,
# entao cobre tanto o instalador quanto os subprocessos que ele spawna.
ENV JAVA_TOOL_OPTIONS="-Xmx2g"

# -console    : instalador em modo texto (sem GUI)
# -continue   : nao pede confirmacao (S/N) durante a instalacao
# -treinamento: instala como ambiente de treino/teste, nao producao
RUN java -jar /tmp/installer.jar -console -continue -treinamento \
    && rm -f /tmp/installer.jar


FROM mirror.gcr.io/library/eclipse-temurin:8-jre-jammy AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    procps \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/^# *pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen \
    && locale-gen pt_BR.UTF-8

# Mesmo UID/GID que o instalador do PostgreSQL embutido usou no estagio
# "installer" pra rodar o initdb sem ser root (confirmado: uid=1000,
# gid=1000). Sem isso, os arquivos de data/ (donos numericos = 1000)
# ficam orfaos no estagio runtime, sem nenhum usuario "postgres" pra
# mapear esse UID -- e o entrypoint.sh falha ao tentar "su postgres"
# porque esse usuario nao existe aqui.
RUN groupadd -g 1000 postgres \
    && useradd -u 1000 -g 1000 -m -s /bin/bash postgres

COPY --from=installer /opt/e-SUS /opt/e-SUS
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
