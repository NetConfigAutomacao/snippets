# NetConfig Snippets

Coleção de scripts e utilitários mantidos pela equipe NetConfig.Automaçao.

## Conteúdo

- **Agent Installer** – automatiza a instalação do NetConfig Agent (Docker + Traefik + certificados). Documentação completa em [`agent/README.md`](agent/README.md).

## Uso rápido do Agent Installer

Para instalar direto sem clonar o repositório:

```bash
curl -fsSL https://raw.githubusercontent.com/NetConfigAutomacao/snippets/refs/heads/main/agent/install.sh | sh
```

> Prefira executar o comando como root ou adicione `sudo` antes de `sh`.

Outros componentes serão documentados em diretórios próprios à medida que forem adicionados.
