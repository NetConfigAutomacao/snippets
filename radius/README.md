# NetConfig Radius Installer

Este diretorio contem o instalador automatizado do NetConfig Radius. O script `radius/install.sh` prepara Docker, Traefik, MySQL, `radius-api` e `radius-server` em hosts Debian/Ubuntu.

## Instalacao Rapida

Execute o instalador como **root** ou com `sudo`.

**Via repositorio clonado**

```bash
git clone https://github.com/NetConfigAutomacao/snippets.git
cd snippets
sudo radius/install.sh
```

**Via one-liner**

```bash
curl -fsSL https://raw.githubusercontent.com/NetConfigAutomacao/snippets/refs/heads/main/radius/install.sh | sudo sh
```

## Pre-requisitos

- Host Debian/Ubuntu (ou derivado).
- Pelo menos 4 GB de RAM e 4 vCPUs para evitar contenção com banco, API e servidor RADIUS.
- Acesso externo SSH por IPv4 público ou IPv6 com privilégios de root ou sudo.
- Conectividade com a internet durante e pós instalação para instalação de pacotes, download das imagens Docker e comunicação com o servidor da NetConfig.
- Pacotes tratados pelo instalador: `Docker`, `curl`, `openssl` e `cron` quando o auto update estiver habilitado.
- Pacote opcional: `jq`, util quando o host tambem precisa de merge mais seguro de configuracao Docker em outros fluxos.
- Portas liberadas:
  - `9443/tcp` (API HTTPS via Traefik)
  - `1812/udp` (RADIUS authentication)
  - `1813/udp` (RADIUS accounting)

## Aviso para VM compartilhada

Se o host ja executa outros servicos ou containers:

- confirme se as portas estão livres;
- revise com cuidado `--no-install-vm-docker` e `--no-update-vm`.

## Convivência com o NetConfig Agent

O Radius cria a própria rede Docker `radius-internal`, sem faixa fixa: ela é
sorteada do pool padrão do Docker (`172.17.0.0/16` a `172.31.0.0/16`).

Se o NetConfig Agent estiver instalado na mesma máquina, não há conflito — o
agente usa uma faixa própria e reservada (`198.19.166.0/24`) e não altera o
pool padrão, justamente para não mexer em redes de terceiros no host.

Vale a mesma precaução de sempre: nenhum equipamento gerenciado deve estar
endereçado na faixa que o Docker sorteou para `radius-internal`. Confira com
`docker network inspect radius-internal`.

## Flags disponiveis

| Flag                                            | Descricao                                                                                                   |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `--unattended`, `--no-prompt`, `--no-ask`, `-y` | Executa sem prompts interativos.                                                                            |
| `--reinstall`                                   | Remove instalacao anterior em `/opt/netconfig-radius` (containers, volumes e arquivos) e reinstala do zero. |
| `--no-install-vm-docker`                        | Nao instala Docker/curl/openssl. Apenas valida se ja estao disponiveis no host.                             |
| `--no-update-vm`                                | Pula a atualizacao seletiva dos pacotes exigidos pelo instalador.                                          |
| `--tag VERSION`                                 | Define uma unica tag para `netconfigsup/radius-db`, `netconfigsup/radius-api` e `netconfigsup/radius-server` (padrao: `latest`). |
| `--no-auto-update`                              | Nao cria o agendamento automatico de atualizacao em `/etc/cron.d/netconfig-radius`.                        |
| `--update-weekday N`                            | Define o dia da semana do update automatico (`0-6`). Deve ser usado junto com `--update-hour` e `--update-minute`. |
| `--update-hour N`                               | Define a hora do update automatico (`0-23`). Deve ser usado junto com `--update-weekday` e `--update-minute`. |
| `--update-minute N`                             | Define o minuto do update automatico (`0-59`). Deve ser usado junto com `--update-weekday` e `--update-hour`. |
| `--help`, `-h`                                  | Exibe ajuda e sai.                                                                                          |

Se nenhum dos tres parametros `--update-*` for informado, o instalador escolhe automaticamente:

- dia da semana `0` ou `6`
- hora entre `3` e `5`
- minuto entre `0` e `59`

Se um dos parametros `--update-*` for informado, os tres precisam ser enviados juntos.

### Exemplos com flags

```bash
# Modo sem prompts
sudo radius/install.sh --unattended

# Instalar uma tag especifica para toda a stack (recomendado para producao)
sudo radius/install.sh --tag v1.2.3

# Reinstalar do zero
sudo radius/install.sh --reinstall --unattended

# Nao atualizar VM e nao instalar dependencias automaticamente
sudo radius/install.sh --no-update-vm --no-install-vm-docker

# Desabilitar criacao do cron de auto update
sudo radius/install.sh --no-auto-update

# Definir janela fixa para auto update: sabado as 03:15
sudo radius/install.sh --update-weekday 6 --update-hour 3 --update-minute 15
```

## Variaveis de ambiente

| Variavel         | Descricao                                                                     | Exemplo                      |
| ---------------- | ----------------------------------------------------------------------------- | ---------------------------- |
| `RADIUS_API_KEY` | Define manualmente a chave da API. Se omitida, o script gera automaticamente. | `RADIUS_API_KEY=chave-forte` |

Exemplo:

```bash
sudo RADIUS_API_KEY="minha-chave-radius" radius/install.sh --tag v1.2.3
```

## Limites de recursos dos containers

Cada container tem teto de CPU e memoria, para que um servico que trave ou vaze
memoria nao consuma a VM inteira. Os valores abaixo sao os padroes; para mudar
qualquer um, acrescente a chave ao `/opt/netconfig-radius/.env` e rode
`docker compose up -d` — o compose le a variavel em tempo de execucao e usa o
padrao quando ela nao existe.

| Container | CPU | Memoria | Chaves |
| --- | --- | --- | --- |
| `netconfig_radius_db` | `2` | `1g` | `RADIUS_DB_CPU_LIMIT`, `RADIUS_DB_MEM_LIMIT` |
| `netconfig_radius_api` | `1` | `512m` | `RADIUS_API_CPU_LIMIT`, `RADIUS_API_MEM_LIMIT`, `RADIUS_API_GOMEMLIMIT` (`384MiB`) |
| `netconfig_radius_server` | `1` | `512m` | `RADIUS_SERVER_CPU_LIMIT`, `RADIUS_SERVER_MEM_LIMIT` |
| `netconfig_radius_traefik` | `1` | `512m` | `RADIUS_TRAEFIK_CPU_LIMIT`, `RADIUS_TRAEFIK_MEM_LIMIT` |

O teto somado e 2,5 GB, dentro dos 4 GB exigidos nos pre-requisitos.

Os quatro containers tambem passaram a rotacionar o log do Docker
(`RADIUS_LOG_MAX_SIZE`, padrao `10m`, e `RADIUS_LOG_MAX_FILE`, padrao `5`);
antes disso o `json-file` crescia sem limite ate encher o disco.

Os limites vivem no `docker-compose.yml`, entao chegam a uma instalacao ja
existente somente quando o instalador roda de novo — o `update.sh` nao reescreve
o compose.

## Reinicio automatico (autoheal)

O stack inclui o container `netconfig_radius_autoheal`, o mesmo usado em
producao. Ele observa os containers marcados com `autoheal=true` e reinicia
aquele cujo healthcheck passar para `unhealthy` — a falha que o
`restart: unless-stopped` nao enxerga, porque aquele so reage a processo que
termina.

| Container | Healthcheck | Autoheal atua? |
| --- | --- | --- |
| `netconfig_radius_db` | `mysqladmin ping` (no compose) | Sim |
| `netconfig_radius_api` | `wget /api/healthy` (na propria imagem) | Sim |
| `netconfig_radius_traefik` | `/ping` num entrypoint interno `:8082` | Sim |
| `netconfig_radius_server` | nenhum | Nao — ver abaixo |

O `radius-server` recebe a label, mas fica inerte por decisao: o freeradius nao
expoe uma verificacao em que este instalador possa confiar, e um healthcheck
errado faria o autoheal reiniciar em laco um servidor RADIUS saudavel. A
verificacao correta e um probe `Status-Server` com o segredo do proprio
servidor, o que pertence a imagem e nao ao instalador.

O `/ping` do Traefik fica num entrypoint que **nao** e publicado no host: de
fora, na `9443`, esse caminho responde 404.

Ajuste por `.env`: `AUTOHEAL_IMAGE`, `AUTOHEAL_VERSION`, `AUTOHEAL_INTERVAL`
(padrao `30`), `AUTOHEAL_START_PERIOD` (padrao `300`), `AUTOHEAL_CPU_LIMIT`
(`0.5`) e `AUTOHEAL_MEM_LIMIT` (`128m`).

O autoheal monta o socket do Docker em leitura e escrita, porque reiniciar
container e escrita — o que equivale a root nessa maquina. E o unico container
do stack com esse acesso.

## Como funciona o acesso HTTPS

- O HTTPS e aplicado no acesso externo da API pelo Traefik (`9443/tcp`).
- A comunicacao interna API <-> banco pode operar sem SSL.
- O instalador usa a imagem `netconfigsup/radius-db` para inicializar o schema do banco.
- O instalador gera um arquivo `.env` com `RADIUS_TAG`, `RADIUS_API_KEY` e `MYSQL_ROOT_PASSWORD`.
- O compose gerado configura `RADIUS_DB_DSN` com `tls=false` para evitar falhas de bootstrap quando o MySQL anuncia SSL com certificado nao confiavel para o container da API.

## Pos-instalacao

- Checar status dos containers:
  ```bash
  cd /opt/netconfig-radius
  sudo docker compose ps
  ```
- Ver logs da API:
  ```bash
  sudo docker logs -f netconfig_radius_api
  ```
- Reiniciar stack:
  ```bash
  cd /opt/netconfig-radius
  sudo docker compose restart
  ```
- Atualizar imagens:
  ```bash
  cd /opt/netconfig-radius
  sudo docker compose pull
  sudo docker compose up -d
  ```
- Atualizar imagens via script:
  ```bash
  sudo /opt/netconfig-radius/update.sh
  ```
- Logs do auto update:
  ```bash
  ls -lah /opt/netconfig-radius/logs/
  ```

Por padrao, o instalador cria `/etc/cron.d/netconfig-radius` para executar o `update.sh` semanalmente. Se o arquivo ja existir e nenhum `--update-*` for informado, ele e preservado. Use `--no-auto-update` para nao criar esse cron.

## Estrutura gerada

```text
/opt/netconfig-radius/
|- docker-compose.yml
|- .env
|- update.sh
|- logs/                         # Logs do auto update via cron
|- traefik/
|  |- certs/selfsigned.crt
|  |- certs/selfsigned.key
|  `- dynamic/selfsigned.yml
`- radius-db-data (volume Docker)
```

## Solucao de problemas

- **Container da API nao fica healthy**:
  - confira `sudo docker logs -f netconfig_radius_api`
  - confira se o banco esta healthy: `sudo docker ps`
- **Erro `ERROR 2026 (HY000): TLS/SSL error: Certificate verification failure`**:
  - confira se o `docker-compose.yml` gerado contem `RADIUS_DB_DSN: raduser:radpass@tcp(radius-db:3306)/raddb?parseTime=true&tls=false`
  - confirme se a imagem `netconfigsup/radius-db:<tag>` foi baixada e iniciada corretamente
- **Erro HTTP 504 na API (`https://host:9443`)**:
  - confira se a network foi criada com nome fixo `radius-internal`
  - confirme as labels `radius.stack=true` e `traefik.docker.network=radius-internal` no servico `radius-api`
- **Porta em uso**:
  - finalize servicos que estejam usando `9443/tcp`, `1812/udp` ou `1813/udp`.
- **Host com outras aplicacoes**:
  - revise as opcoes avancadas antes de repetir o reinstall automatico.

## Suporte

Apos a instalacao, use a `RADIUS API Key` exibida no terminal para registrar o servico no NetConfig.
