Golfe Server (Dart)
====================

This folder contains a lightweight Dart Shelf server for the Golfe app. It exposes REST endpoints and a WebSocket endpoint for real-time updates. It stores data in Postgres.

Quick start
-----------

1. Copy `.env.example` to `.env` and fill in your Postgres credentials.

2. Install dependencies and run:

```powershell
cd server
dart pub get
dart run bin/server.dart
```

3. Run migrations (use psql or your preferred tool):

```bash
psql "host=DB_HOST port=DB_PORT user=DB_USER dbname=DB_NAME" -f migrations/init.sql
```

API
---
- `GET /health` — health check
- `GET /games` — list games
- `GET /games/{id}` — get game
- `POST /games` — create game (JSON: course, date, holes)
- `PATCH /games/{id}` — update game (e.g. status)
- `POST /games/{id}/strokes` — add stroke (JSON: player_name, hole_number, strokes)
- `GET /ws/games/{id}` — WebSocket endpoint for live updates about a game

Reverse proxy (nginx)
----------------------

Example nginx config to proxy requests and enable TLS (replace domain and cert paths):

```
server {
  listen 80;
  server_name example.com;
  return 301 https://$host$request_uri;
}

server {
  listen 443 ssl;
  server_name example.com;

  ssl_certificate /etc/letsencrypt/live/example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```

Notes:
- WebSocket support requires `proxy_set_header Upgrade $http_upgrade;` and `Connection "upgrade";`.
- Consider running the server behind `systemd` (example below) and using `certbot` for TLS.

systemd service example (save as `/etc/systemd/system/golfe-server.service`):

```
[Unit]
Description=Golfe Dart Server
After=network.target

[Service]
WorkingDirectory=/opt/golfe/server
ExecStart=/usr/bin/dart run bin/server.dart
Restart=on-failure
Golfe — Server (Dart Shelf)

Resumo
- Backend implementado em Dart usando `shelf` + `shelf_router`.
- Expõe API REST para gerir jogos, jogadores, rounds e tacadas (strokes).
- Fornece WebSocket para sincronização em tempo-real: `ws://<host>/ws/games/<gameId>`.
- Usa PostgreSQL; o esquema consolidado está em `server/migrations/init.sql`.

Pré-requisitos
- Dart SDK instalado.
- PostgreSQL acessível e configurado.

Variáveis de ambiente úteis
- `DATABASE_URL` — URI do Postgres (ex.: `postgres://user:pass@localhost:5432/dbname`).
- `PORT` — porta para o servidor (padrão: `18080`).

Migrations
- O esquema canónico encontra-se em `server/migrations/init.sql`.
- Ferramenta de aplicação de migrations: `server/tools/apply_migration.dart`.

Aplicar o esquema (PowerShell):
```powershell
cd 'c:\Users\rodri\OneDrive\Ambiente de Trabalho\APPs\golfe\server'
dart pub get
dart run tools/apply_migration.dart
```

Executar o servidor
```powershell
cd server
dart run bin/server.dart
```
Por omissão o servidor escuta em `http://localhost:18080` (ou `PORT`).

Principais endpoints HTTP
- `GET /health` — verifica saúde do servidor.
- `GET /games` — lista jogos.
- `GET /games/:id` — obter jogo.
- `POST /games` — criar jogo.
- `PATCH /games/:id` — atualizar jogo.
- `POST /games/:id/players` — adicionar jogador.
- `POST /games/:id/strokes` — inserir tacada (aceita `round_id` opcional). Retorna `201`.
- `POST /games/:id/rounds` — criar round (Pitch & Putt).
- `PATCH /games/:id/rounds/:rid/complete` — finalizar round.
- `POST /games/:id/finalize` — finalizar jogo e computar vencedor.

WebSocket
- `ws://<host>/ws/games/<gameId>`: cliente recebe mensagens do tipo `stroke`, `game_state`, `round_created`, `round_completed`, `player_joined`, `game_finalized`.
- `ws://<host>/ws/admin/updates`: notificações de administração (opcional).

Autenticação e permissões
- Endpoints sensíveis exigem `Authorization: Bearer <api_key>`.
- Roles: `admin`, `editor`, `player`, `viewer` (cada uma com permissões específicas).

Notas
- O schema consolidado incluiu `rounds` e `strokes.round_id` para suportar rounds.
- Uma rota admin de debug para listar strokes foi removida do código principal para evitar exposição acidental.

Ficheiros principais
- `server/lib/src/app.dart` — lógica das rotas e WebSockets.
- `server/migrations/init.sql` — esquema SQL consolidado.
- `server/bin/server.dart` — entrypoint.

Debug
- Healthcheck:
```powershell
Invoke-RestMethod -Uri http://localhost:18080/health -Method GET
```
- Ver conexões WS: `ws_connections.log` (o servidor escreve quando sockets conectam).

Contribuição
- Ao alterar a API, documente a rota e actualize este README.
