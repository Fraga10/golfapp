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
User=www-data

[Install]
WantedBy=multi-user.target
```

Security / Auth
---------------
This scaffold does not implement full authentication. For multi-user production, add JWT authentication or API keys and enforce HTTPS.
