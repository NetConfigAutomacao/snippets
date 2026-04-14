# NetConfig Agent Installer

Este diretório contém o instalador automatizado do NetConfig Agent. O script `agent/install.sh` prepara Docker, Traefik e o próprio agente em hosts Debian/Ubuntu, habilitando conectividade IPv4/IPv6 e oferecendo três modos de exposição HTTP/HTTPS.

## Instalação Rápida

Execute o instalador como **root** ou com `sudo`, escolhendo a abordagem que preferir.

**Via repositório clonado**

```bash
git clone https://github.com/NetConfigAutomacao/snippets.git
cd snippets
sudo agent/install.sh
```

**Via one-liner (não-interativo)**

```bash
curl -fsSL https://raw.githubusercontent.com/NetConfigAutomacao/snippets/refs/heads/main/agent/install.sh | sudo sh
```

> **Nota:** O instalador verifica se está rodando como root. O one-liner acima não exibe prompts interativos (veja seção [Execução não-interativa](#execução-não-interativa)).

## Pré-requisitos

- Host Debian/Ubuntu (ou derivado).
- Pelo menos 4 GB de RAM e 4 vCPUs para evitar contenção com Agent e Traefik.
- Acesso externo SSH por IPv4 público ou IPv6 com privilégios de root ou sudo.
- Conectividade com a internet durante e pós instalação para instalação de pacotes, download das imagens Docker e comunicação com o servidor da NetConfig.
- Pacotes esperados no host: `Docker`, `curl`, `openssl` e `cron` quando o auto update estiver habilitado.
- Pacote opcional: `jq`, usado para merge mais seguro de configuracao Docker quando necessario.
- Portas liberadas:
  - `2222/tcp` (túnel SSH do agente)
  - `8443/tcp` (HTTPS do agente via Traefik)
  - `8080/tcp` (Opcional: HTTP do agente via Traefik caso não seja possível HTTPS)
  - `80/tcp` (Opcional: utilizada pelo desafio ACME ao usar Let's Encrypt)
- DNS apontando para o host caso vá utilizar Let's Encrypt.

## Aviso para VM compartilhada

Se o host já executa outros serviços ou containers:

- revise cuidadosamente as opções avançadas antes do reinstall;
- confirme portas livres e impacto de instalar Docker/dependências.

## Flags disponíveis

O script aceita as seguintes flags de linha de comando:

| Flag                                            | Descrição                                                                                                                                                                               |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--unattended`, `--no-prompt`, `--no-ask`, `-y` | Executa sem prompts interativos. Usa valores padrão (HTTPS com certificado autoassinado).                                                                                               |
| `--no-install-vm-docker`                        | **Não instala** Docker, curl ou openssl. Apenas verifica se estão instalados. Se algum estiver faltando, o script para com erro. Útil quando você gerencia as dependências manualmente. |
| `--no-update-vm`                                | Pula a atualização seletiva dos pacotes exigidos pelo instalador. Ainda instala dependências se necessário (a menos que `--no-install-vm-docker` também esteja ativa).                    |
| `--tag VERSION`                                 | Especifica a tag da imagem do agente (padrão: `latest`). Exemplo: `--tag v1.23.1`                                                                                                       |
| `--no-auto-update`                              | Não cria o agendamento automático de atualização em `/etc/cron.d/netconfig-agent`.                                                                                                            |
| `--update-weekday N`                            | Define o dia da semana do update automático (`0-6`). Deve ser usado junto com `--update-hour` e `--update-minute`.                                                                      |
| `--update-hour N`                               | Define a hora do update automático (`0-23`). Deve ser usado junto com `--update-weekday` e `--update-minute`.                                                                           |
| `--update-minute N`                             | Define o minuto do update automático (`0-59`). Deve ser usado junto com `--update-weekday` e `--update-hour`.                                                                           |
| `--help`, `-h`                                  | Exibe mensagem de ajuda e sai.                                                                                                                                                          |

Se nenhum dos três parâmetros `--update-*` for informado, o instalador escolhe automaticamente:

- dia da semana `0` ou `6`
- hora entre `3` e `5`
- minuto entre `0` e `59`

Se um dos parâmetros `--update-*` for informado, os três precisam ser enviados juntos.

### Exemplos com flags

```bash
# Não interativo, sem atualizar pacotes do sistema
sudo agent/install.sh --unattended --no-update-vm

# Apenas verifica dependências, não instala nada
sudo agent/install.sh --no-install-vm-docker --no-update-vm

# Desabilitar criação do cron de auto update
sudo agent/install.sh --no-auto-update

# Modo silencioso com Let's Encrypt
sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com agent/install.sh --unattended

# Instalar versão específica do agente
sudo agent/install.sh --tag v1.23.1

# Versão específica com Let's Encrypt
sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com agent/install.sh --tag v1.23.1

# Definir janela fixa para auto update: sábado às 03:15
sudo agent/install.sh --update-weekday 6 --update-hour 3 --update-minute 15
```

## Execução não-interativa

Quando o script é executado via pipe (`curl ... | sh`), ele **não exibe prompts interativos**. O comportamento padrão nesse caso é:

- **HTTPS com certificado autoassinado** (modo mais seguro)
- Sem perguntar domínio ou email
- Ideal para automações e scripts

Para personalizar a configuração sem interatividade, use **variáveis de ambiente**:

```bash
# Let's Encrypt automático
curl -fsSL ... | sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com sh

# Apenas HTTP (sem HTTPS)
curl -fsSL ... | sudo DISABLE_TLS=true sh

# Modo não-interativo explícito
curl -fsSL ... | sudo sh -s -- --unattended
```

## Variáveis de ambiente

| Variável      | Descrição                                          | Exemplo             |
| ------------- | -------------------------------------------------- | ------------------- |
| `DOMAIN`      | Domínio para Let's Encrypt                         | `agent.exemplo.com` |
| `ACME_EMAIL`  | Email para notificações Let's Encrypt              | `dev@exemplo.com`   |
| `DISABLE_TLS` | Desabilita HTTPS (HTTP apenas)                     | `true`              |
| `UNATTENDED`  | Modo não-interativo (equivalente a `--unattended`) | `true`              |

> **Importante:** Variáveis de ambiente devem ser exportadas antes do comando ou definidas na mesma linha (antes do comando).

## Modos de operação

O instalador identifica automaticamente o cenário desejado com base nas variáveis ambiente e nas respostas fornecidas.

### 1. Somente HTTP (sem TLS)

Adequado para ambientes de teste ou redes internas onde TLS não é necessário.

```bash
sudo DISABLE_TLS=true agent/install.sh
```

O instalador:

- Atualiza seletivamente os pacotes exigidos pelo instalador e instala `curl`, `openssl` e `Docker`, se necessário.
- Sobe o stack Docker com Traefik escutando apenas em `:8080`.
- Publica o NetConfig Agent em `http://<host>:8080` e mantém o túnel `2222/tcp`.

Ao término, as chaves de registro (`API Key` e `SSH Key`) são exibidas com espaçamento extra para facilitar a cópia.

### 2. HTTPS com certificado autoassinado (padrão)

Padrão quando HTTPS é aceito mas nenhum domínio/e-mail é informado.

**Execução interativa (com repositório clonado):**

1. Execute `sudo agent/install.sh`
2. No prompt "Enable HTTPS via Traefik? [Y/n]", pressione **Enter** para aceitar.
3. Deixe os campos de domínio e e-mail vazios para usar o certificado autoassinado.

**Execução não-interativa (one-liner):**

```bash
curl -fsSL ... | sudo sh
```

O instalador irá:

- Gerar um certificado autoassinado válido por **3 anos** em `/opt/netconfig-agent/traefik/certs/selfsigned.{crt,key}`, incluindo SAN para `localhost`, `127.0.0.1` e o IP principal do host.
- Configurar Traefik para servir:
  - `http://<host>:8080`
  - `https://<host>:8443`
- Manter o arquivo `selfsigned.yml` dentro da pasta dinâmica do Traefik.

Importe o `.crt` no trust store da sua máquina para evitar avisos de segurança. Quando o instalador é executado de forma não interativa (ex.: automações), o modo autoassinado é habilitado por padrão; utilize `DISABLE_TLS=true` se não quiser HTTPS.

### 3. HTTPS automático com Let's Encrypt

Utilize quando já tiver um domínio apontando para o host.

```bash
sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com agent/install.sh
```

> Também é possível rodar interativamente (com repositório clonado), aceitar HTTPS no prompt e digitar domínio/e-mail quando solicitado.

O instalador:

- Cria `/opt/netconfig-agent/traefik/acme/acme.json` (permissões 600) para armazenar certificados.
- Habilita um entrypoint dedicado `acme=:80` para realizar o desafio HTTP do Let's Encrypt (resolver `le`).
- Publica o agente em `http://agent.exemplo.com:8080` e `https://agent.exemplo.com:8443`, utilizando o certificado emitido automaticamente.
- Mantém a porta 80 liberada para renovações futuras do ACME.

## Pós-instalação

- Checar status dos containers:
  ```bash
  cd /opt/netconfig-agent
  sudo docker compose ps
  ```
- Reiniciar o stack:
  ```bash
  sudo docker compose restart
  ```
- Logs do agente:
  ```bash
  sudo docker logs -f netconfig_agent
  ```
- Atualizar a imagem do agente via script:
  ```bash
  sudo /opt/netconfig-agent/update.sh
  ```
- Logs do auto update:
  ```bash
  ls -lah /opt/netconfig-agent/logs/
  ```
- Atualizar a imagem do agente manualmente:
  ```bash
  cd /opt/netconfig-agent
  sudo docker compose pull
  sudo docker compose up -d
  ```

Por padrão, o instalador cria `/etc/cron.d/netconfig-agent` para executar o `update.sh` semanalmente. Se o arquivo já existir e nenhum `--update-*` for informado, ele é preservado. Use `--no-auto-update` para não criar esse cron.

## Estrutura gerada

```
/opt/netconfig-agent/
├── docker-compose.yml
├── update.sh
├── logs/                        # Logs do auto update via cron
├── traefik/
│   ├── acme/acme.json           # Apenas no modo Let's Encrypt
│   ├── certs/selfsigned.*       # Apenas no modo autoassinado
│   └── dynamic/selfsigned.yml   # Referência ao certificado self-signed
└── agent_data/                  # Persistência do NetConfig Agent
```

## Solução de problemas

- **Let's Encrypt não gera certificado**: verifique DNS, liberação das portas 80/8080/8443 e se nenhum outro serviço está ocupando-as.
- **Aviso de certificado inválido**: importe `/opt/netconfig-agent/traefik/certs/selfsigned.crt` no trust store (modo autoassinado).
- **Porta em uso**: finalize serviços que utilizem 80, 8080, 8443 ou 2222 antes de reexecutar o instalador.
- **Docker não está instalado (com --no-install-vm-docker)**: remova a flag `--no-install-vm-docker` ou instale o Docker manualmente antes de executar o script.
- **Host com outras aplicações**: revise as opções avançadas antes de repetir o reinstall automático.

## Suporte

Registre o agente em https://app.netconfig.com.br/agents usando as chaves exibidas ao final e, se precisar de ajuda, contate o suporte NetConfig informando o `API Key` correspondente.
