# e-SUS AB PEC — Docker image

## Objetivo

Montar uma imagem Docker (via um container runtime local, não Docker
Desktop) para rodar o e-SUS AB PEC localmente, a partir do instalador oficial
`eSUS-AB-PEC-5.5.28-Linux64.jar`. Solução própria e enxuta (não usar o projeto de
terceiros `esus-pec-docker`), exposta na porta 8080.

Restrição importante: qualquer ajuste de configuração do container runtime deve ser
**local a este projeto**, sem alterar a config global (`~/Library/Application
Support/<runtime>/container/buildkit/config/config.toml`), pois o mirror
`docker-upstream.internal` configurado lá é usado por outros projetos.

## O que já foi descoberto sobre o `.jar`

Não é uma aplicação pronta — é o **instalador oficial** (engenharia reversa via
bytecode, classe `br.gov.saude.esus.installers.installer.Main`, baseado em
picocli). Ele empacota e instala em `/opt/e-SUS`:
- um JRE próprio (`/opt/e-SUS/jre/current`)
- um PostgreSQL 9.6 embutido, instalado via `postgresql-9.6.13-1-linux-x64.run`
  (instalador clássico EnterpriseDB/BitRock), porta **5433**
- o app real, `pec-bundle.jar` (Spring Boot, escuta na porta **8080**), em
  `/opt/e-SUS/webserver/`, iniciado por `/opt/e-SUS/webserver/standalone.sh`

Flags úteis do instalador (picocli):
- `-console` — modo texto, sem GUI
- `-continue` — não pede confirmação (S/N) durante a instalação
- `-treinamento` — instala como ambiente de treino/teste, não produção
- `-uninstall`, `-help`
- grupo `-url/-username/-password` — usar um Postgres externo em vez do embutido
- `-cert-domain/-cert-port` — TLS automático (não usado aqui)

`Environment.hasSystemd()` roda `ps --no-headers -o comm 1` e exige `systemd`; em
container isso nunca é verdade e não importa (nosso `entrypoint.sh` já assume
que não há systemd).

## Arquitetura escolhida

`Dockerfile` em 2 estágios:
1. **installer** (`mirror.gcr.io/library/eclipse-temurin:17-jdk-jammy`) — roda
   `java -jar eSUS-AB-PEC-5.5.28-Linux64.jar -console -continue -treinamento`
   para gerar `/opt/e-SUS`.
2. **runtime** (`mirror.gcr.io/library/eclipse-temurin:17-jre-jammy`) — copia só
   `/opt/e-SUS` + `entrypoint.sh` (sobe o Postgres embutido e depois
   `standalone.sh` em foreground).

Usamos `mirror.gcr.io/library/...` em vez de `eclipse-temurin:...` direto **só
neste projeto**, porque a config global do container runtime redireciona `docker.io` para
o proxy interno (`docker-upstream.internal`), que não conseguimos
usar aqui. Apontar para um host diferente de `docker.io` evita esse
redirecionamento sem tocar na config global.

Build precisa ser forçado para **amd64** (`--arch amd64` no build):
os binários embutidos (JRE, Postgres) são x86-64 only; a máquina é arm64,
então depende de emulação Rosetta (confirmada disponível via checagem do
runtime).

## Problemas já resolvidos (na ordem em que apareceram)

1. **DNS do container runtime fora do ar** (checagem do runtime mostrava `❌ DNS
   (TCP/UDP)`) — resolvido reiniciando o runtime por completo.
2. **`Cannot run program "/bin/sh" (in directory "")`** — o cwd do processo
   Java vinha vazio nesse ambiente de build. Fix: `WORKDIR /tmp` antes do RUN
   do instalador.
3. **"Esta ferramenta suporta apenas systemd"** — `Environment.hasSystemd()`
   roda `ps --no-headers -o comm 1`. Fix: script `ps` falso em
   `/usr/local/bin/ps` (prioridade no PATH sobre `/usr/bin/ps`) que responde
   `systemd` só para essa chamada exata e repassa todo o resto pro `ps` real.
4. **"Esta ferramenta suporta apenas x64"** — `Environment.isX64()` roda
   `file -L /sbin/init` e verifica se a saída contém `"64-bit"`. A imagem base
   não tem `/sbin/init`. Fix: instalar pacote `file` + criar
   `/sbin/init -> /bin/bash` (símlink pra um ELF 64-bit real e garantido de
   existir).

Essas 4 correções estão aplicadas no `Dockerfile` atual e funcionam: o
instalador passa das validações de ambiente, instala o JRE, e começa a
instalar o PostgreSQL.

## Erro atual (ainda não resolvido)

Durante a instalação do PostgreSQL embutido, dentro do fluxo completo do
instalador eSUS, o comando

```
./postgresql-9.6.13-1-linux-x64.run --create_shortcuts 0 --mode unattended \
  --unattendedmodeui none --superaccount postgres --superpassword "esus" \
  --serverport 5433 --servicename e-SUS-AB-PostgreSQL \
  --prefix "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64" \
  --datadir "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64/data"
```

falha com:

```
Problem running post-install step. Installation may not complete correctly
The script was called with an invalid command line
```

(exit code 1 do `.run`), o que faz o instalador eSUS abortar com "Não foi
possível preparar o Banco de Dados." (o processo Java em si termina com exit
code 0, então o `docker build`/build do container runtime não marca a etapa como erro —
só percebemos porque `/opt/e-SUS` fica incompleto).

### O que já foi eliminado como causa

Extraí o `.run` do PostgreSQL diretamente do `.jar` original
(`container/database/postgresql-9.6.13-1-linux-x64.run`, 114MB) e rodei ele
**isoladamente** (fora do fluxo do instalador eSUS), num container limpo
(`mirror.gcr.io/library/eclipse-temurin:17-jdk-jammy`, `--arch amd64`), com
os mesmos argumentos (só trocando `--prefix`/`--datadir` para
`/tmp/pginstall` em vez do caminho aninhado real) — **funcionou perfeitamente
duas vezes**, com "Installation completed", inclusive:
- uma vez com `/bin/sh` padrão (dash)
- outra vez com `/bin/sh` trocado por `bash` (replicando uma das mudanças do
  Dockerfile)

Ou seja: **a hipótese de dash-vs-bash está descartada** — o `ln -sf bash
/bin/sh` no Dockerfile não é a causa do problema (pode ser revertido, já que
não ajuda nem atrapalha comprovadamente, mas também não resolve nada).

### Hipóteses ainda não testadas

Como o `.run` funciona isolado mas falha dentro do fluxo completo, a
diferença deve estar em algo específico do contexto real de execução:
- **Caminho aninhado real**: `--prefix "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64"`
  (dentro de `/opt/e-SUS`, criado poucos segundos antes pela etapa do JRE) vs
  o caminho raso `/tmp/pginstall` usado no teste isolado.
- **Diretório de trabalho (cwd)** do processo no momento da chamada: o log
  real mostra `Shell: Diretório: /opt/e-SUS/tmp/database` — o teste isolado
  rodou a partir de `/tmp`.
- **O `ps` falso em `/usr/local/bin/ps`**: pode estar interferindo em alguma
  chamada `ps` feita pelo script de post-install/init do Postgres (ex.:
  checagem se o serviço já está rodando) — o teste isolado não tinha esse
  wrapper.
- Efeito cumulativo de rodar dentro do processo Java do instalador (variáveis
  de ambiente diferentes, ownership/permissões de `/opt/e-SUS` criadas pelo
  próprio instalador, etc.).

### Próximo passo sugerido

Reproduzir o teste isolado mas replicando fielmente o contexto real: usar
`--prefix "/opt/e-SUS/database/postgresql-9.6.13-1-linux-x64"` (caminho
aninhado igual ao real, dentro de uma estrutura `/opt/e-SUS` pré-criada), rodar
a partir de um cwd equivalente a `/opt/e-SUS/tmp/database`, e com o `ps` falso
de `/usr/local/bin/ps` ativo — isolando cada uma dessas 3 variáveis (uma de
cada vez, se possível) até reproduzir o "invalid command line" fora do fluxo
completo do instalador. Isso permitiria ler o `bitrock_installer.log`
detalhado do caso que efetivamente falha (no fluxo completo dentro do
build do container runtime, esse log específico ainda não foi extraído/lido).

## Arquivos do projeto

- `Dockerfile` — build de 2 estágios descrito acima, com as 4 correções já
  aplicadas.
- `entrypoint.sh` — sobe o Postgres embutido (tenta
  `/etc/init.d/e-SUS-AB-PostgreSQL start`, senão `pg_ctl` direto) e depois
  `exec /opt/e-SUS/webserver/standalone.sh`. Ainda não testado de ponta a
  ponta porque o build da etapa `installer` não conclui.
