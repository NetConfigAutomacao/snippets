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

**Via one-liner**
```bash
curl -fsSL https://raw.githubusercontent.com/NetConfigAutomacao/snippets/refs/heads/main/agent/install.sh | sh
```
> Inclua `sudo` antes de `sh` se não estiver executando como root.

## Pré-requisitos

- Host Debian/Ubuntu (ou derivado) com privilégios de root.
- Conectividade com a internet para instalação de pacotes e download das imagens Docker.
- Portas liberadas:
  - `8080/tcp` (HTTP do agente via Traefik)
  - `8443/tcp` (HTTPS do agente via Traefik)
  - `2222/tcp` (túnel SSH do agente)
  - `80/tcp` (utilizada pelo desafio ACME ao usar Let's Encrypt)
- DNS apontando para o host caso vá utilizar Let’s Encrypt.

## Modos de operação

O instalador identifica automaticamente o cenário desejado com base nas variáveis ambiente e nas respostas fornecidas.

### 1. Somente HTTP (sem TLS)
Adequado para ambientes de teste ou redes internas onde TLS não é necessário.

```bash
sudo agent/install.sh DISABLE_TLS=true
```

O instalador:
- Atualiza os pacotes do sistema e instala `curl`, `openssl` e Docker, se necessário.
- Sobe o stack Docker com Traefik escutando apenas em `:8080`.
- Publica o NetConfig Agent em `http://<host>:8080` e mantém o túnel `2222/tcp`.

Ao término, as chaves de registro (`API Key` e `SSH Key`) são exibidas com espaçamento extra para facilitar a cópia.

### 2. HTTPS com certificado autoassinado (padrão)
Padrão quando HTTPS é aceito mas nenhum domínio/e-mail é informado.

Passos:
1. Execute `sudo agent/install.sh` (ou use o one-liner).
2. No prompt “Enable HTTPS via Traefik? [Y/n]”, pressione **Enter** para aceitar.
3. Deixe os campos de domínio e e-mail vazios para usar o certificado autoassinado.

O instalador irá:
- Gerar um certificado autoassinado válido por **3 anos** em `/opt/netconfig-agent/traefik/certs/selfsigned.{crt,key}`, incluindo SAN para `localhost`, `127.0.0.1` e o IP principal do host.
- Configurar Traefik para servir:
  - `http://<host>:8080`
  - `https://<host>:8443`
- Manter o arquivo `selfsigned.yml` dentro da pasta dinâmica do Traefik.

Importe o `.crt` no trust store da sua máquina para evitar avisos de segurança. Quando o instalador é executado de forma não interativa (ex.: automações), o modo autoassinado é habilitado por padrão; utilize `DISABLE_TLS=true` se não quiser HTTPS.

### 3. HTTPS automático com Let’s Encrypt
Utilize quando já tiver um domínio apontando para o host.

```bash
sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com agent/install.sh
```
> Também é possível rodar sem variáveis, aceitar HTTPS no prompt e digitar domínio/e-mail quando solicitado.

O instalador:
- Cria `/opt/netconfig-agent/traefik/acme/acme.json` (permissões 600) para armazenar certificados.
- Habilita um entrypoint dedicado `acme=:80` para realizar o desafio HTTP do Let’s Encrypt (resolver `le`).
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
- Atualizar a imagem do agente:
  ```bash
  cd /opt/netconfig-agent
  sudo docker compose pull
  sudo docker compose up -d
  ```

## Estrutura gerada

```
/opt/netconfig-agent/
├── docker-compose.yml
├── traefik/
│   ├── acme/acme.json           # Apenas no modo Let’s Encrypt
│   ├── certs/selfsigned.*       # Apenas no modo autoassinado
│   └── dynamic/selfsigned.yml   # Referência ao certificado self-signed
└── agent_data/                  # Persistência do NetConfig Agent
```

## Solução de problemas

- **Let’s Encrypt não gera certificado**: verifique DNS, liberação das portas 80/8080/8443 e se nenhum outro serviço está ocupando-as.
- **Aviso de certificado inválido**: importe `/opt/netconfig-agent/traefik/certs/selfsigned.crt` no trust store (modo autoassinado).
- **Porta em uso**: finalize serviços que utilizem 80, 8080, 8443 ou 2222 antes de reexecutar o instalador.

## Suporte

Registre o agente em https://app.netconfig.com.br/tunnels usando as chaves exibidas ao final e, se precisar de ajuda, contate o suporte NetConfig informando o `API Key` correspondente.
