# NetConfig Agent Installer

Este repositório disponibiliza o instalador automatizado do NetConfig Agent. O script `scripts/install_agent.sh` prepara Docker, Traefik e o próprio agente em hosts Debian/Ubuntu, habilitando conectividade IPv4/IPv6 e oferecendo três modos de exposição HTTP/HTTPS.

## Instalação Rápida

Escolha a forma que preferir para executar o instalador (sempre como **root** ou com `sudo`).

**Via repo local**
```bash
git clone https://github.com/NetConfigAutomacao/snippets.git
cd snippets
sudo scripts/install_agent.sh
```

**Via one-liner**
```bash
curl -fsSL https://raw.githubusercontent.com/NetConfigAutomacao/snippets/refs/heads/main/scripts/install_agent.sh | sh
```
> Acrescente `sudo` antes de `sh` caso não esteja executando como root.

## Pré-requisitos

- Host Debian/Ubuntu (ou derivado) com privilégios de root.
- Conectividade com a internet para instalar pacotes e baixar imagens Docker.
- Portas liberadas:
  - `8080/tcp` (HTTP do agente via Traefik)
  - `8443/tcp` (HTTPS do agente via Traefik)
  - `2222/tcp` (túnel SSH do agente)
  - `80/tcp` (apenas para o desafio ACME quando Let’s Encrypt estiver ativo)
- DNS apontando para o host caso vá utilizar Let’s Encrypt.

## Modos de operação

O script detecta automaticamente o cenário desejado. Execute o instalador e siga as instruções abaixo conforme sua necessidade.

### 1. Somente HTTP (sem TLS)
Use quando TLS não é necessário (testes ou ambientes internos).

```bash
sudo scripts/install_agent.sh DISABLE_TLS=true
```

O instalador:
- Atualiza pacotes e instala `curl`, `openssl` e Docker, caso precisem.
- Sobe o stack Docker com Traefik escutando apenas em `:8080`.
- Publica o NetConfig Agent em `http://<host>:8080` e mantém o túnel `2222/tcp`.

No final, o script exibirá as chaves de registro (`API Key` e `SSH Key`) com espaçamento extra para facilitar a cópia.

### 2. HTTPS com certificado autoassinado (padrão)
Este é o comportamento padrão quando você aceita habilitar HTTPS, mas não informa domínio/e-mail.

Passos:
1. Execute `sudo scripts/install_agent.sh` (ou o one-liner).
2. Quando perguntado “Enable HTTPS via Traefik? [Y/n]”, pressione **Enter** para aceitar.
3. Deixe os campos de domínio/e-mail vazios para usar o certificado autoassinado.

O instalador irá:
- Gerar um certificado autoassinado válido por **3 anos** em `/opt/netconfig-agent/traefik/certs/selfsigned.{crt,key}`, incluindo SAN para `localhost`, `127.0.0.1` e o IP principal do host.
- Configurar Traefik para servir:
  - `http://<host>:8080`
  - `https://<host>:8443`
- Manter o arquivo `selfsigned.yml` na pasta dinâmica do Traefik.

Importe o `.crt` no seu trust store para evitar avisos do navegador. Em execuções não interativas (ex.: via automação), o script habilita HTTPS com o mesmo certificado autoassinado por padrão; use `DISABLE_TLS=true` caso não deseje TLS.

### 3. HTTPS automático com Let’s Encrypt
Requer um domínio público já apontado para o host.

```bash
sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com scripts/install_agent.sh
```
> Você também pode rodar sem variáveis, aceitar HTTPS no prompt e informar domínio/e-mail quando solicitado.

O instalador:
- Cria `/opt/netconfig-agent/traefik/acme/acme.json` (permissões 600) para armazenar certificados.
- Abre um entrypoint exclusivo `acme=:80` para o desafio HTTP do Let’s Encrypt (resolver `le`).
- Gera o stack com Traefik servindo o agente em `http://agent.exemplo.com:8080` e `https://agent.exemplo.com:8443`, usando o certificado emitido automaticamente.
- Mantém a porta 80 reservada para renovações futuras.

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
