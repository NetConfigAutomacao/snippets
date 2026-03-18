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

- Host Debian/Ubuntu (ou derivado) com privilegios de root.
- Conectividade com internet para instalar dependencias e baixar imagens Docker.
- Portas liberadas:
  - `9443/tcp` (API HTTPS via Traefik)
  - `1812/udp` (RADIUS authentication)
  - `1813/udp` (RADIUS accounting)

## Flags disponiveis

| Flag                                            | Descricao                                                                                                   |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `--unattended`, `--no-prompt`, `--no-ask`, `-y` | Executa sem prompts interativos.                                                                            |
| `--reinstall`                                   | Remove instalacao anterior em `/opt/netconfig-radius` (containers, volumes e arquivos) e reinstala do zero. |
| `--no-install-vm-docker`                        | Nao instala Docker/curl/openssl. Apenas valida se ja estao disponiveis no host.                             |
| `--no-update-vm`                                | Pula `apt-get update && apt-get upgrade`.                                                                   |
| `--tag VERSION`                                 | Define uma unica tag para `netconfigsup/radius-db`, `netconfigsup/radius-api` e `netconfigsup/radius-server` (padrao: `latest`). |
| `--help`, `-h`                                  | Exibe ajuda e sai.                                                                                          |

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
```

## Variaveis de ambiente

| Variavel         | Descricao                                                                     | Exemplo                      |
| ---------------- | ----------------------------------------------------------------------------- | ---------------------------- |
| `RADIUS_API_KEY` | Define manualmente a chave da API. Se omitida, o script gera automaticamente. | `RADIUS_API_KEY=chave-forte` |

Exemplo:

```bash
sudo RADIUS_API_KEY="minha-chave-radius" radius/install.sh --tag v1.2.3
```

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

## Estrutura gerada

```text
/opt/netconfig-radius/
|- docker-compose.yml
|- .env
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

## Suporte

Apos a instalacao, use a `RADIUS API Key` exibida no terminal para registrar o servico no NetConfig.
