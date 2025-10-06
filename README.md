# NetConfig Agent Installer

Este repositório contém o instalador automatizado do NetConfig Agent. O script `scripts/install_agent.sh` provisiona Docker, Traefik e o próprio agente em uma máquina Debian/Ubuntu, garantindo conectividade IPv4/IPv6 e oferecendo múltiplas opções de HTTPS.

A seguir descrevemos como executar o instalador em três cenários: somente HTTP, HTTPS com certificado autoassinado e HTTPS automático via Let's Encrypt.

## Pré-requisitos

- Máquina com Debian ou derivado, com acesso root (`sudo`).
- DNS apontado para o host caso deseje Let’s Encrypt.
- Porta 80 e 443 liberadas para Traefik; porta 2222 para o túnel SSH do agente.

## Execução sem HTTPS (somente HTTP)

Use quando apenas acesso local/teste é necessário e você não quer TLS.

1. Faça login como root ou utilize `sudo`.
2. Rode:
   ```bash
   sudo scripts/install_agent.sh DISABLE_TLS=true
   ```
3. O instalador irá:
   - Atualizar pacotes, instalar `curl`, `openssl` (se faltarem) e Docker.
   - Criar o stack Docker com Traefik ouvindo apenas em `:80` + dashboard `:8080`.
   - Expor o agente na porta 80 via Traefik e manter a porta 2222 para SSH.
4. Acesse o painel em `http://<IP ou hostname>`.
5. Ao final, o script exibirá `API Key` e `SSH Key` para registrar o agente em https://app.netconfig.com.br.

## HTTPS com certificado autoassinado (sem domínio)

Padrão quando você não define domínio/email. Ideal para ambiente que exige TLS mas ainda sem DNS pronto.

1. Execute como root/sudo:
   ```bash
   sudo scripts/install_agent.sh
   ```
2. Quando perguntado *“Enable HTTPS via Traefik? [Y/n]”*, pressione Enter (aceitar).
3. Se não informar domínio/email, o script:
   - Gera certificado autoassinado (`/opt/netconfig-agent/traefik/certs/selfsigned.{crt,key}`) com SAN para `localhost`, `127.0.0.1` e IP primário do host.
   - Configura Traefik para servir HTTPS em `:443` utilizando esse certificado.
4. Acesse via `https://<IP ou hostname>`; o navegador avisará que o certificado é não confiável — importe o `.crt` caso deseje remover o aviso.
5. Dashboard permanece em `https://<IP>:8080` com o mesmo certificado.
6. Chaves de registro (`API Key`, `SSH Key`) são exibidas ao final.

## HTTPS automático com Let's Encrypt (domínio + e-mail)

Use quando o host já responde pelo seu domínio público.

1. Verifique que `DOMÍNIO -> IP` já está resolvendo e portas 80/443 estão abertas.
2. Execute o instalador informando as variáveis de ambiente:
   ```bash
   sudo DOMAIN=agent.exemplo.com ACME_EMAIL=dev@exemplo.com scripts/install_agent.sh
   ```
   - Alternativamente, rode `sudo scripts/install_agent.sh`, aceite HTTPS e informe domínio/e-mail quando solicitado.
3. O script:
   - Pré-cria `traefik/acme/acme.json` (permissões 600) para armazenar certificados.
   - Habilita redirecionamento 80→443 e emite o certificado via ACME HTTP challenge usando Traefik (resolver `le`).
   - Define as labels do serviço do agente apontando para o domínio informado.
4. Acesse `https://agent.exemplo.com`; o certificado deve ser válido (emitido por Let’s Encrypt).
5. Dashboard Traefik: `https://agent.exemplo.com:8080` (mesmo cert).
6. Registre o agente com as chaves apresentadas ao final.

## Comandos úteis pós-instalação

- Ver estado dos containers:
  ```bash
  cd /opt/netconfig-agent
  sudo docker compose ps
  ```
- Reiniciar stack:
  ```bash
  sudo docker compose restart
  ```
- Logs do agente:
  ```bash
  sudo docker logs -f netconfig_agent
  ```
- Atualizar imagem do agente:
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
│   ├── acme/acme.json           # Apenas no modo Let's Encrypt
│   ├── certs/selfsigned.*       # Apenas no modo autoassinado
│   └── dynamic/selfsigned.yml   # Configuração TLS dinâmica
└── agent_data/                  # Persistência do NetConfig Agent
```

## Solução de problemas

- **Certificado Let’s Encrypt não emite**: confirme DNS, portas liberadas e ausência de proxies filtrando HTTP.
- **Certificado autoassinado não é aceito**: importe `/opt/netconfig-agent/traefik/certs/selfsigned.crt` no trust store.
- **Portas em uso**: encerrre serviços que ocupam 80/443/2222 antes de rodar o instalador.

## Suporte

Dúvidas adicionais? Registre o agente pelo painel e contate o suporte NetConfig informando o `API Key`.
