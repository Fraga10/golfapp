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

Auto-update (pull automático) e Webhooks
- **In-container auto-pull**: o `server/docker-entrypoint.sh` suporta uma opção simples `GIT_AUTO_PULL=1` (definível em `server/.env`) que faz polling para `origin/<branch>` e, se encontrar commits novos, faz `git pull` + executa migrations e reinicia o processo do servidor.
	- Requisitos: o diretório `.git` deve estar presente dentro do container, o container tem acesso de rede ao repositório remoto e as credenciais necessárias (se privadas).
	- Variáveis úteis (em `server/.env`): `GIT_AUTO_PULL=1`, `GIT_PULL_INTERVAL=30`, `GIT_REMOTE=origin`, `GIT_BRANCH=main`.

- **Webhook (recomendado)**: em vez de polling in-container, a abordagem recomendada é configurar um *GitHub Webhook* que notifica um *deploy hook* no seu host quando houver pushes. O fluxo típico:
	- No host onde o backend corre (por ex. um servidor ou VM) rode um *webhook receiver* (um pequeno HTTP endpoint) que verifica a assinatura HMAC do GitHub e executa `git pull && ./server/migrate.sh && docker compose up -d --build` ou comandos equivalentes.
	- Vantagens: resposta imediata ao push, menor uso de recursos (sem polling), possibilidade de verificar payload/assinatura e controlar permissões.

Como configurar um webhook básico
	1. Crie um endpoint no host para receber `POST` do GitHub. Exemplo mínimo (Node.js + Express):

```js
// webhook-listener.js (exemplo)
const crypto = require('crypto');
const express = require('express');
const { exec } = require('child_process');

const SECRET = process.env.WEBHOOK_SECRET; // configure no GitHub

const app = express();
app.use(express.json());

function verifySignature(req) {
	const sig = req.headers['x-hub-signature-256'];
	if (!sig) return false;
	const hmac = crypto.createHmac('sha256', SECRET);
	const digest = 'sha256=' + hmac.update(JSON.stringify(req.body)).digest('hex');
	return crypto.timingSafeEqual(Buffer.from(digest), Buffer.from(sig));
}

app.post('/payload', (req, res) => {
	if (!verifySignature(req)) return res.status(401).send('invalid signature');
	// Optionally check req.body.ref to only react to certain branches
	// Pull & restart steps (example: adapt to your host commands)
	exec('cd /path/to/repo && git pull && docker compose up -d --build', (err, stdout, stderr) => {
		if (err) console.error(err);
		console.log(stdout, stderr);
	});
	res.status(200).send('ok');
});

app.listen(7777, () => console.log('webhook listener running'));
```

	2. Exponha o endpoint (`/payload`) publicamente (via NAT, reverse proxy, or ngrok for testing).
	3. No GitHub → *Settings → Webhooks* → *Add webhook*: use `Content type: application/json`, pre-shared secret (o mesmo de `WEBHOOK_SECRET`), e selecione o evento `Push`.

Segurança e boas práticas
- Use a *secret* no webhook e valide a assinatura no receiver.
- Dê permissões mínimas à conta que fará `git pull` (SSH key ou token) e evite colocar chaves sensíveis dentro de containers publicados.
- Registe logs das atualizações e das saídas de `git pull`/migrations para debug e auditoria.

Alternativa (GitHub Actions → deploy to host)
- Se não quiser expor um endpoint público, use uma GitHub Action que, em pushes ao `main`, faça SSH para o host e execute `git pull && docker compose up -d --build`. Esta é frequentemente a opção mais segura/controle centralizado.


Quick troubleshooting
- Checar saúde do servidor:

```powershell
Invoke-RestMethod -Uri http://localhost:18080/health -Method GET
```

- Checar WebSocket (exemplo): `ws://localhost:18080/ws/games/<gameId>`

Contribuição
- Siga as convenções de migrations e atualize a documentação quando alterar a API.

Para detalhes específicos sobre server e client veja os respetivos `README.md`.
