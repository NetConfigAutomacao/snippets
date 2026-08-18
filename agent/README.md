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
- Nenhum equipamento gerenciado endereçado em `198.19.166.0/24` — é a rede interna do agente (ver "Rede interna do agente").
- Portas liberadas:
  - `2222/tcp` (túnel SSH do agente)
  - `8443/tcp` (HTTPS do agente via Traefik)
  - `8080/tcp` (Opcional: HTTP do agente via Traefik caso não seja possível HTTPS)
  - `80/tcp` (Opcional: utilizada pelo desafio ACME ao usar Let's Encrypt)
- DNS apontando para o host caso vá utilizar Let's Encrypt.

## Rede interna do agente

O agente roda em container e alcança os equipamentos a partir da rede Docker
`netconfig`, fixada pelo instalador em:

| Família | Faixa |
|---|---|
| IPv4 | `198.19.166.0/24` |
| IPv6 | `2001:db8:198:166::/64` |

**Nenhum equipamento gerenciado pode estar nessa faixa.** Um endereço dentro
dela é tratado pelo kernel como vizinho local do container: o tráfego não sai
da máquina do agente, e o equipamento aparece como inacessível sem que haja
qualquer problema nele.

A faixa foi escolhida justamente para tornar isso improvável — `198.18.0.0/15`
é reservada pela RFC 2544 para testes de equipamento de rede, não é atribuída
pela IANA e não aparece na tabela de roteamento da internet. Antes, o Docker
sorteava a rede do pool padrão (`172.17.0.0/16` a `172.31.0.0/16`), que colide
com endereçamento de cliente com frequência.

Se algum equipamento seu já usa `198.19.166.0/24`, avise o suporte antes de
instalar: a faixa da rede pode ser alterada, mas precisa ser feita antes do
agente subir.

Instalações feitas antes dessa mudança continuam na faixa sorteada pelo Docker
até serem reinstaladas. O diagnóstico do equipamento no NetConfig identifica o
conflito nos dois casos.

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
| `--reinstall`                                   | **Destrutiva.** Apaga containers, volume de dados e arquivos em `/opt/netconfig-agent` e instala de novo. O agente volta com chaves novas — reregistre-o, ou use o botão de reinstalação no NetConfig, que troca as chaves sozinho. |
| `--check`                                       | Inspeciona a instalação e relata o que está faltando, sem alterar nada. Sai com `0` quando está em dia e `1` quando algo exige reinstalação.                                             |
| `--no-auto-update`                              | Não cria o agendamento automático de atualização em `/etc/cron.d/netconfig-agent`.                                                                                                            |
| `--update-weekday N`                            | Define o dia da semana do update automático (`0-6`). Deve ser usado junto com `--update-hour` e `--update-minute`.                                                                      |
| `--update-hour N`                               | Define a hora do update automático (`0-23`). Deve ser usado junto com `--update-weekday` e `--update-minute`.                                                                           |
| `--update-minute N`                             | Define o minuto do update automático (`0-59`). Deve ser usado junto com `--update-weekday` e `--update-hour`.                                                                           |
| `--no-time-sync`                                | Pula a verificação de relógio. O instalador apenas **informa** o estado do relógio — nunca instala, configura nem ajusta nada.                                                            |
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
| `NETCONFIG_URL` | Backend NetConfig usado para medir o relógio (padrão `https://app.netconfig.com.br`) | `https://netconfig.cliente.com.br` |

### Instalação avançada

Nada aqui precisa ser editado no script: todos os valores abaixo aceitam
sobrescrita por variável de ambiente na chamada do instalador. Um valor
inválido é recusado antes de qualquer instalação, com a mensagem do que se
esperava.

```sh
AGENT_DIR=/srv/netconfig-agent \
SSH_TUNNEL_PORT=2322 \
BIND_ADDRESS=10.0.0.5 \
  ./install.sh
```

| Variável | Padrão | Para que serve |
| --- | --- | --- |
| `AGENT_NETWORK_SUBNET` | `198.19.166.0/24` | Rede interna do agente. Troque se a faixa já for usada por equipamento seu |
| `AGENT_NETWORK_SUBNET_V6` | `2001:db8:198:166::/64` | Mesma rede, IPv6. Precisa ser diferente de `DOCKER0_CIDR_V6` |
| `SSH_TUNNEL_PORT` | `2222` | Porta publicada do túnel SSH |
| `HTTP_PORT` | `8080` | Porta publicada do HTTP via Traefik |
| `HTTPS_PORT` | `8443` | Porta publicada do HTTPS via Traefik |
| `ACME_HTTP_PORT` | `80` | Porta do desafio ACME (Let's Encrypt) |
| `BIND_ADDRESS` | vazio (todas as interfaces) | Endereço do host onde as portas são publicadas. Use IPv6 entre colchetes: `[2001:db8::1]` |
| `AGENT_IMAGE` | `netconfigsup/agent` | Imagem do agente. Aponte para o seu registry espelhado |
| `AGENT_TAG` | `latest` | Tag da imagem do agente. Equivale a `--tag`, que tem precedência |
| `TRAEFIK_IMAGE` | `traefik` | Imagem do Traefik |
| `TRAEFIK_VERSION` | `v3.6.1` | Tag do Traefik |
| `AGENT_DIR` | `/opt/netconfig-agent` | Diretório da instalação |
| `SKIP_DOCKER_DAEMON_CONFIG` | `false` | `true` impede o instalador de escrever `daemon.json` e reiniciar o Docker. Exige IPv6 já habilitado no daemon |
| `DOCKER0_CIDR_V6` | `2001:db8:1::/64` | Prefixo IPv6 da bridge padrão do Docker, exigido junto de `"ipv6": true`. O stack não usa essa bridge |
| `LOG_MAX_SIZE` | `10m` | Rotação de log dos containers |
| `LOG_MAX_FILE` | `5` | Quantidade de arquivos de log mantidos |
| `AGENT_CPU_LIMIT` | `2` | Teto de CPU do container do agente. O Go 1.25 deriva o `GOMAXPROCS` desse limite |
| `AGENT_MEM_LIMIT` | `1g` | Teto de memória do container. Sem ele, um agente que vaza memória derruba a VM inteira |
| `AGENT_GOMEMLIMIT` | `768MiB` | Alvo de memória do coletor de lixo do Go, abaixo do teto acima, para que o GC reaja antes do OOM kill |
| `TRAEFIK_CPU_LIMIT` | `1` | Teto de CPU do container do Traefik |
| `TRAEFIK_MEM_LIMIT` | `512m` | Teto de memória do Traefik. Um Traefik morto pela falta de memória do host derruba o acesso HTTP ao agente |
| `AUTOHEAL_IMAGE` | `willfarrell/autoheal` | Imagem do autoheal, que reinicia container marcado como `unhealthy` |
| `AUTOHEAL_VERSION` | `latest` | Tag do autoheal |
| `AUTOHEAL_INTERVAL` | `30` | Intervalo, em segundos, entre verificações de saúde |
| `AUTOHEAL_START_PERIOD` | `300` | Carência, em segundos, antes de considerar reiniciar um container recém-subido |
| `AUTOHEAL_CPU_LIMIT` | `0.5` | Teto de CPU do autoheal |
| `AUTOHEAL_MEM_LIMIT` | `128m` | Teto de memória do autoheal |

### Arquivo `.env`

O instalador grava `/opt/netconfig-agent/.env` com os valores que o
`docker-compose.yml` lê em tempo de execução:

`AGENT_IMAGE`, `AGENT_TAG`, `TRAEFIK_IMAGE`, `TRAEFIK_VERSION`,
`SSH_TUNNEL_PORT`, `HTTP_PORT`, `HTTPS_PORT`, `ACME_HTTP_PORT`,
`AGENT_NETWORK_SUBNET`, `AGENT_NETWORK_SUBNET_V6`, `LOG_MAX_SIZE`,
`LOG_MAX_FILE`, `AGENT_CPU_LIMIT`, `AGENT_MEM_LIMIT`, `AGENT_GOMEMLIMIT`,
`TRAEFIK_CPU_LIMIT`, `TRAEFIK_MEM_LIMIT`, `AUTOHEAL_IMAGE`, `AUTOHEAL_VERSION`,
`AUTOHEAL_INTERVAL`, `AUTOHEAL_START_PERIOD`, `AUTOHEAL_CPU_LIMIT`,
`AUTOHEAL_MEM_LIMIT`.

## Relógio da VM

O agente assina cada requisição com um timestamp e recusa qualquer uma que
esteja a mais de **300 segundos** do próprio relógio. Fora dessa janela ele não
responde mais **nada** — ping, SNMP, proxy SSH e diagnóstico falham juntos, e a
tela do NetConfig mostra o agente como se estivesse morto.

O caso comum é a VM sem nenhum serviço de horário: `timedatectl set-ntp true`
responde `Failed to set ntp: NTP not supported` quando não há
`systemd-timesyncd` nem `chrony` instalado.

O instalador (e o `--check`) verifica e **avisa**, sem mexer na máquina:

- nomeia o serviço NTP em execução, ou avisa que não há nenhum;
- mede a diferença contra o header `Date` do próprio servidor NetConfig — é
  esse o relógio com que o HMAC é comparado, não um servidor NTP público;
- passando de 60 s, avisa que o agente vai responder 401 a tudo até o relógio
  ser corrigido, e que a API key **não** é a causa;
- imprime o procedimento a executar, e segue com a instalação de qualquer
  forma: o agente instala normalmente, só não autentica enquanto o relógio
  estiver errado.

Instalar o serviço de horário é decisão de quem administra a VM. O
procedimento impresso é o do [guia do NTP.br](https://ntp.br/guia/linux/),
publicado pelo NIC.br:

```sh
apt-get install -y chrony

# drop-in, sem reescrever um /etc/chrony/chrony.conf existente
cat > /etc/chrony/conf.d/ntp-br.conf <<EOF
server a.st1.ntp.br iburst nts
server b.st1.ntp.br iburst nts
server c.st1.ntp.br iburst nts
server d.st1.ntp.br iburst nts
server e.st1.ntp.br iburst nts
server gps.nu.ntp.br iburst nts
server gps.jd.ntp.br iburst nts
server gps.ce.ntp.br iburst nts
EOF

systemctl enable --now chrony
chronyc makestep    # diferença grande levaria horas no slew padrão
chronyc tracking    # confere; veja também chronyc sources
```

`nts` exige chrony 4.0 ou mais novo (`chronyd --version`) e TCP/4460 liberado
para a troca de chaves; em versões antigas, remova a palavra `nts`. O NTP em si
usa UDP/123.

Em container, o relógio pertence ao **host**: o instalador aponta isso e não
imprime procedimento para rodar dentro da VM.

## Reinício automático (autoheal)

O stack inclui o container `netconfig_autoheal`, o mesmo usado em produção. Ele
observa os containers marcados com a label `autoheal=true` — hoje o agente e o
Traefik — e reinicia aquele cujo healthcheck passar para `unhealthy`.

Isso cobre a falha que o `restart: unless-stopped` não cobre: um processo que
continua vivo mas parou de responder. O `restart` só reage a processo que
termina.

Para o Traefik ter healthcheck, o instalador habilita o `/ping` num entrypoint
interno (`:8082`), que **não** é publicado no host — de fora, esse caminho
responde 404.

O autoheal monta o socket do Docker em modo leitura e escrita, porque reiniciar
container é escrita. Isso equivale a root na máquina: é o único container do
stack com esse acesso, e nenhum outro deve receber.

Isso permite ajustar qualquer um deles depois, sem reinstalar:

```sh
cd /opt/netconfig-agent
vim .env
docker compose up -d
```

Reexecutar o instalador **nunca sobrescreve valor já presente no arquivo** —
ele apenas acrescenta as chaves que faltam, que é como uma configuração nova
chega a uma instalação antiga sem desfazer os ajustes de quem administra.

Uma chave que você comentar conta como ausente e volta com o valor padrão, já
que o compose precisa dela. Para desativar um ajuste, volte o valor padrão em
vez de comentar a linha.

As demais variáveis (`AGENT_DIR`, `SKIP_DOCKER_DAEMON_CONFIG`,
`DOCKER0_CIDR_V6`, `DOMAIN`, `ACME_EMAIL`) são decisões de instalação e não
entram no `.env`: o compose não as lê.

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
- Atualizar o agente via script (imagem + configurações novas):
  ```bash
  sudo /opt/netconfig-agent/update.sh
  ```
  Além de puxar a imagem, ele acrescenta ao `.env` as chaves que passaram a
  existir desde a instalação, sem tocar nas que já estão lá. É por esse caminho
  que uma configuração nova chega a uma instalação antiga sem reinstalar.
- Verificar se a instalação está em dia, sem alterar nada:
  ```bash
  sudo /opt/netconfig-agent/install.sh --check
  ```
  Ele separa o que o `update.sh` resolve sozinho do que exige reinstalação — a
  faixa da rede interna, por exemplo, não pode ser renumerada com containers
  ligados nela.
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
├── .env                         # Valores lidos pelo compose (ver "Arquivo .env")
├── update.sh
├── logs/                        # Logs do auto update via cron
├── traefik/
│   ├── acme/acme.json           # Apenas no modo Let's Encrypt
│   ├── certs/selfsigned.*       # Apenas no modo autoassinado
│   └── dynamic/selfsigned.yml   # Referência ao certificado self-signed
└── agent_data/                  # Persistência do NetConfig Agent (API key e chave do túnel)
```

`agent_data/` é apagado por `--reinstall`, então o agente volta com chaves
novas. Reinstalando pelo NetConfig isso é transparente — a plataforma troca as
chaves no cadastro existente, mantendo nome e equipamentos. Reinstalando pela
linha de comando, reregistre o agente com as chaves exibidas ao final.

## Solução de problemas

### Equipamento inacessível logo após instalar

Confira primeiro se o endereço do equipamento cai em `198.19.166.0/24` (ou, em
instalações anteriores a essa mudança, na faixa que o Docker sorteou — veja
`docker network inspect netconfig`). Nesses casos o tráfego não sai da máquina
do agente e o sintoma é idêntico ao de um equipamento desligado. O diagnóstico
do equipamento no NetConfig aponta o conflito diretamente.

- **Let's Encrypt não gera certificado**: verifique DNS, liberação das portas 80/8080/8443 e se nenhum outro serviço está ocupando-as.
- **Aviso de certificado inválido**: importe `/opt/netconfig-agent/traefik/certs/selfsigned.crt` no trust store (modo autoassinado).
- **Porta em uso**: finalize serviços que utilizem 80, 8080, 8443 ou 2222 antes de reexecutar o instalador.
- **Docker não está instalado (com --no-install-vm-docker)**: remova a flag `--no-install-vm-docker` ou instale o Docker manualmente antes de executar o script.
- **Host com outras aplicações**: revise as opções avançadas antes de repetir o reinstall automático.
- **Dúvida se a instalação está completa**: rode `sudo /opt/netconfig-agent/install.sh --check`. Ele lista o que falta e diz se resolve com update ou se exige reinstalação.

## Suporte

Registre o agente em https://app.netconfig.com.br/agents usando as chaves exibidas ao final e, se precisar de ajuda, contate o suporte NetConfig informando o `API Key` correspondente.
