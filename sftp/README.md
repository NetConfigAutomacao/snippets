# NetConfig SFTP Manager Installer

Este diretorio contem o instalador do NetConfig SFTP Manager. O script `sftp/install.sh` prepara Docker, o servidor SFTP e a API de controle em hosts Debian/Ubuntu.

## O que e isso

O SFTP Manager e o repositorio de arquivos de onde os **equipamentos buscam** atualizacoes e licencas.

Ele existe porque a maioria dos fabricantes nao aceita receber arquivo: Datacom DmOS, Cisco IOS/XE e FortiOS tem cliente SFTP/SCP, nao servidor, e esperam que o equipamento va buscar com um `copy <url>`. Para os que aceitam receber — Huawei, MikroTik e Nokia SR Linux — o NetConfig envia direto pela tela **Arquivos do Equipamento**, sem precisar deste container.

## Onde instalar

**Numa maquina dentro da rede do cliente**, tipicamente a mesma que roda o Agent.

Isso nao e preferencia: um equipamento atras do NAT do cliente alcanca uma maquina da propria LAN e nao alcanca nada na nuvem. O NetConfig guarda apenas como falar com a API de controle — o arquivo trafega equipamento&harr;repositorio, sempre dentro da rede do cliente.

## Instalacao Rapida

Execute o instalador como **root** ou com `sudo`.

**Pelo NetConfig** (recomendado)

Em **Integracoes > SFTP Manager > Instalar em uma maquina**, informe endereco e credenciais SSH. O NetConfig executa este script, gera as credenciais e ja registra a instancia. Voce nao precisa copiar chave nenhuma.

**Via repositorio clonado**

```bash
git clone https://github.com/NetConfigAutomacao/snippets.git
cd snippets
sudo sftp/install.sh
```

**Via one-liner**

```bash
curl -fsSL https://raw.githubusercontent.com/NetConfigAutomacao/snippets/refs/heads/main/sftp/install.sh | sudo sh
```

## Pre-requisitos

- Host Debian/Ubuntu (ou derivado).
- Acesso root ou sudo.
- Conectividade com a internet durante a instalacao, para pacotes e imagens Docker.
- Pacotes tratados pelo instalador: `Docker`, `curl` e `openssl` (o `openssl` gera o certificado do Traefik).
- As portas 7777 e 7770 livres (ou outras, via `SFTP_PORT` / `SFTP_API_PORT`).

## Opcoes

| Opcao | Efeito |
|---|---|
| `--unattended` | Nunca pergunta nada. Obrigatorio quando executado pelo NetConfig. |
| `--uninstall` | Remove a instalacao **e os arquivos guardados nela** e sai, sem instalar nada depois. |
| `--reinstall` | Remove a instalacao anterior **e os arquivos guardados nela** antes de instalar. |
| `--no-install-vm-docker` | Nao instala Docker; falha se estiver ausente. |
| `--tag <tag>` | Tag da imagem da API de controle (padrao: `latest`). |
| `--no-auto-update` | Nao agenda a atualizacao semanal. |
| `--update-weekday <0-6>`, `--update-hour <0-23>`, `--update-minute <0-59>` | Horario da atualizacao semanal (os tres juntos, ou nenhum). |
| `--domain <fqdn>` | Emite um certificado Let's Encrypt para o dominio (precisa resolver aqui e porta 80 aberta). Padrao: autoassinado. |
| `--acme-email <email>` | Contato da conta Let's Encrypt (padrao: `admin@<dominio>`). |
| `-h`, `--help` | Mostra a ajuda. |

## Variaveis de ambiente

| Variavel | Padrao | Para que serve |
|---|---|---|
| `SFTP_API_KEY` | gerada | Chave da API de controle, usada pelo NetConfig. |
| `SFTP_PASSWORD` | gerada | Senha do usuario SFTP compartilhado `netconfig`. |
| `SFTP_PORT` | `7777` | Porta SFTP publicada. |
| `SFTP_API_PORT` | `7770` | Porta da API de controle publicada. |
| `SFTP_API_IMAGE` | imagem oficial | Sobrescreve a imagem da API de controle. |
| `SFTP_BIND_ADDRESS` | vazio (todas) | Endereco em que as portas publicadas escutam. Perguntado interativamente quando nao definido. |
| `SFTP_API_IMAGE_URL` | vazio | URL de um tarball `docker save` para carregar a imagem em vez de puxar de um registry. |
| `SFTP_DOMAIN` | vazio | Dominio para emitir um certificado Let's Encrypt (senao, autoassinado). |
| `SFTP_ACME_EMAIL` | `admin@<dominio>` | Contato da conta Let's Encrypt. |

As duas credenciais sao lidas do **ambiente**, nunca de flags: um argumento de linha de comando aparece no historico do shell e na lista de processos da maquina inteira.

Quando nao informadas, sao geradas com 256 bits de aleatoriedade. Rodando o instalador a mao, as duas aparecem no resumo final. **Instalando pelo NetConfig, a senha do SFTP nao fica guardada la**: ela e gerada, entregue a maquina e descartada. Para obte-la depois, leia `/opt/netconfig-sftp/.env` nesta maquina (so root) ou defina uma nova em Integracoes > SFTP Manager > Trocar Senha do SFTP. Prefira deixar o instalador gerar — uma chave escolhida por uma pessoa e uma chave adivinhavel, e nada aqui precisa ser memorizavel.

### Maquina sem acesso a registry

`SFTP_API_IMAGE_URL` aponta para um tarball gerado com `docker save`. Quando definida, o instalador baixa e carrega esse arquivo, adota a tag que vem dentro dele e **nao tenta puxar** a imagem da API de nenhum registry:

```bash
SFTP_API_IMAGE_URL=http://192.0.2.10:8080/netconfig-sftp-api.tar.gz sudo -E sftp/install.sh --unattended
```

Isso e sempre instalacao manual. O NetConfig nunca passa essa variavel: ele instala a partir do script publicado, e uma unica URL num backend multi-tenant nao teria como significar coisas diferentes para clientes diferentes.

Exemplo com portas proprias:

```bash
SFTP_PORT=9001 SFTP_API_PORT=9002 sudo -E sftp/install.sh --unattended
```

> `sudo -E` preserva o ambiente. Sem o `-E`, o sudo descarta as variaveis e o instalador gera credenciais novas.

## O que fica instalado

```
/opt/netconfig-sftp/
  docker-compose.yml
  .env                  # credenciais, legivel so pelo root
  traefik/
    certs/              # certificado autoassinado, chave legivel so pelo root
    dynamic/            # configuracao de TLS do Traefik
```

Tres containers:

- **netconfig-sftp-traefik** — termina o TLS da API de controle. So a API passa por ele; o SFTP nao.
- **netconfig-sftp-server** — OpenSSH servindo os arquivos. Um unico usuario compartilhado (`netconfig`); os arquivos ficam direto em `data/` e o acesso e feito pela senha do SFTP e por links publicos.
- **netconfig-sftp-api** — a API de controle que o NetConfig usa para listar, renomear, publicar e importar. Nunca serve o arquivo em si.

Os arquivos ficam num volume Docker (`sftp-data`) que os dois compartilham. O estado da API fica num volume separado (`sftp-api-state`), de proposito: qualquer coisa dentro de `sftp-data` e baixavel por quem tiver a senha do SFTP.

## Portas

| Porta | Servico |
|---|---|
| 7777 | SFTP (e por aqui que o equipamento busca) |
| 7770 | API de controle (HTTPS) **e** downloads publicos (HTTP ou HTTPS) |

O instalador avisa se voce escolher a **2222** para o SFTP: essa e a porta do tunel SSH do Agent, e os dois costumam cair na mesma maquina.

## Em qual endereco publicar

O instalador lista os enderecos da maquina e pergunta em qual publicar, marcando os que sao alcancaveis pela internet. O padrao continua **todas as interfaces**, que e o do proprio Docker.

Isso importa porque **o Docker publica por cima do firewall do host**: ele escreve as proprias regras de iptables, entao uma porta publicada em todas as interfaces e servida mesmo com o `ufw` ativo. Numa maquina com endereco publico, isso significa a porta SFTP e a API de controle expostas na internet — protegidas apenas pela senha do SFTP e pela chave da API, e com os links publicos baixaveis por qualquer um que os tenha, por desenho.

Em execucao nao interativa (`--unattended`, que e como o NetConfig chama), a pergunta nao aparece: define-se `SFTP_BIND_ADDRESS`, ou fica em todas as interfaces com um aviso no log quando a maquina tem endereco publico.

```bash
SFTP_BIND_ADDRESS=192.168.1.10 sudo -E sftp/install.sh --unattended
```

O instalador recusa um endereco que a maquina nao tem — sem isso o erro so apareceria no `docker compose up`, depois de tudo instalado.

## Seguranca

Como nos instaladores do Agent e do Radius, o Traefik termina TLS na frente da API de controle, com **certificado autoassinado** gerado na instalacao. Nao ha CA que emita certificado para um IP que so existe dentro da rede do cliente, entao o NetConfig **nao valida a cadeia**: quem autentica cada chamada e a assinatura HMAC feita com a chave da API. O TLS esta ali para a chave nao trafegar em claro na LAN.

Na porta 7770 convivem dois routers, e o protocolo decide qual atende:

| Caminho | HTTP simples | HTTPS |
|---|---|---|
| `/l/…`, `/f/…` (download público) | serve | serve |
| API de controle | **nao roteado** (404) | serve |

Uma porta do Traefik e so um listener TCP; TLS e decidido por router, entao um router com TLS so casa com conexao TLS e um sem TLS so casa com texto claro. A API de controle existe apenas no router com TLS — em HTTP ela nao da 401, ela nao e roteada. Os downloads publicos atendem dos dois jeitos porque e isso que um `copy <url>` de equipamento precisa: a maioria nao aceita certificado autoassinado e boa parte nem fala HTTPS. Servi-los em claro nao enfraquece nada — um link publico e sem autenticacao por desenho, e e justamente isso que permite ao equipamento busca-lo.

Com um **dominio** (`--domain` ou `SFTP_DOMAIN`), o Traefik emite um certificado Let's Encrypt (desafio HTTP-01 na porta 80) e passa a apresenta-lo em todo o trafego TLS — inclusive os links publicos `/f` e `/l` abertos no navegador — entao o aviso de certificado some. Precisa do dominio resolvendo para esta maquina e da porta 80 acessivel pela internet. Sem dominio, segue o autoassinado.

O lado SFTP **nao** passa pelo Traefik: ele fala HTTP, e SSH ja traz criptografia e host key proprios.

O que voce deve saber:

- A API de controle **nao deve ser exposta a internet**. Quem tem a chave dela manda no repositorio inteiro.
- Esta instancia serve **uma unica empresa**; nao ha diretorio por empresa. O usuario SFTP e compartilhado e ve tudo o que esta no volume: quem tem a senha do SFTP le e escreve todos os arquivos da instancia.
- Links publicos sao **sem autenticacao** por desenho — e isso que permite um `copy <url>` de equipamento que nao sabe apresentar credencial. Publique so o que pode ser baixado por quem tiver o link.

## Atualizacao

```bash
cd /opt/netconfig-sftp
docker compose pull && docker compose up -d
```

Nao ha auto-update por cron aqui, diferente do Agent e do Radius: o repositorio guarda arquivos que uma atualizacao no meio de uma transferencia interromperia, e a decisao de quando reiniciar e de quem opera a rede.

## Remocao

```bash
sudo sftp/install.sh --uninstall
```

Para os containers, apaga os volumes (**os arquivos guardados vao junto**), remove o agendamento de atualizacao e o diretorio `/opt/netconfig-sftp`. Pelo NetConfig, e o que a chave **Remover tambem da maquina** faz no dialogo de remocao da instancia.

A mao, se preferir:

```bash
cd /opt/netconfig-sftp
docker compose down -v      # -v apaga tambem os arquivos guardados
rm -rf /opt/netconfig-sftp
rm -f /etc/cron.d/netconfig-sftp
```

## Diagnostico

```bash
cd /opt/netconfig-sftp
docker compose ps
docker compose logs --tail 50 sftp-api
curl -fsSk https://127.0.0.1:7770/api/healthy   # -k: certificado autoassinado
```

Se o NetConfig nao conseguir falar com a instancia, confira nesta ordem: o container esta de pe, a porta da API responde no proprio host, e o firewall entre o NetConfig e essa maquina permite a porta da API.
