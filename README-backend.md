# Golfapp — Backend (minimal)

Este repositório contém o serviço backend do Golfapp (Dart Shelf + Postgres).

Arquivos essenciais:

- `server/` — código fonte do backend (inclui `bin/server.dart`, `lib/`, `migrations/`)
- `server/Dockerfile` — imagem Docker multi-stage para executar o backend
- `server/.env` — (não está comprometido) ficheiro com variáveis de ambiente (DB, PORT, etc.)

Como executar localmente com Docker (teste rápido):

1. Cria o ficheiro de variáveis `server/.env` com as credenciais do Postgres. Exemplo mínimo:

```
PORT=8080
DB_HOST=127.0.0.1
DB_PORT=5432
DB_NAME=golfe_db
DB_USER=golfe_user
DB_PASS=golfepass
```

2. Build da imagem localmente a partir do `server`:

```bash
docker build -t golfe-backend:local -f server/Dockerfile server
```

3. Executar o container (exemplo simples):

```bash
docker run -d --name golfe-backend -p 8080:8080 --env-file server/.env --restart unless-stopped golfe-backend:local
```

4. Verificar o `ping` de saúde:

```bash
curl -sfS http://127.0.0.1:8080/ping && echo "pong"
```

Se preferires usar `docker compose`, coloca o `docker-compose.yml` na raiz e executa `docker compose up -d`.

Notas de segurança:
- Não comites `server/.env` — este ficheiro contém segredos.
- Protege a branch `main` no GitHub se for usada em produção.
