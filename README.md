# golfe

Golfe é um aplicativo Flutter para registo de tacadas e rounds (suporte a Pitch & Putt).

Este repositório contém duas peças principais:
- `server/` — backend em Dart (Shelf) que expõe a API REST e WebSocket para sincronização em tempo-real.
- Flutter app (root + `lib/`) — cliente mobile/desktop com UI de jogo ao vivo.

Resumo rápido (passos mínimos para executar o projecto)

1. Configure o Postgres e aplique o esquema (arquivo canónico em `server/migrations/init.sql`).
2. Execute o servidor Dart (padrão: `http://localhost:8080`).
3. Abra a app Flutter (`flutter run`) — o cliente usa `API_BASE_URL` (opcional) ou `http://localhost:8080` por omissão.

Server — Docker
- **`server/.env.example`**: copie para `server/.env` e preencha as variáveis (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`, `PORT`).
- **Rodar o servidor com Docker Compose (usa `server/.env`)**: no diretório `server/` execute:

```powershell
cd server
docker compose up --build
```

- **Observações sobre o banco de dados**: o arquivo `server/docker-compose.yml` não inclui um serviço Postgres — a configuração de BD deve ser fornecida através de `server/.env` (por exemplo um Postgres externo ou um container separado). Exemplos:
	- Para usar um Postgres local (no host Windows), configure `DB_HOST=host.docker.internal` no `server/.env`.
	- Para subir rapidamente um Postgres via Docker (não gerenciado pelo compose acima):

```powershell
docker run -e POSTGRES_USER=golfe_user -e POSTGRES_PASSWORD=change_me -e POSTGRES_DB=golfe_db -p 5432:5432 -d postgres:15
```

	Depois edite `server/.env` para apontar para o host/porta corretos.

Onde ler mais
- `server/README.md` — instruções para configurar, rodar e detalhes das rotas do backend.
- `lib/README.md` — notas sobre o cliente Flutter, boxes Hive usados, e pontos de extensão.

Quick troubleshooting
- Checar saúde do servidor:

```powershell
Invoke-RestMethod -Uri http://localhost:18080/health -Method GET
```

- Checar WebSocket (exemplo): `ws://localhost:18080/ws/games/<gameId>`

Contribuição
- Siga as convenções de migrations e atualize a documentação quando alterar a API.

Para detalhes específicos sobre server e client veja os respetivos `README.md`.
