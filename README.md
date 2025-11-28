# golfe

Golfe é um aplicativo Flutter para registo de tacadas e rounds (suporte a Pitch & Putt).

Este repositório contém duas peças principais:
- `server/` — backend em Dart (Shelf) que expõe a API REST e WebSocket para sincronização em tempo-real.
- Flutter app (root + `lib/`) — cliente mobile/desktop com UI de jogo ao vivo.

Resumo rápido (passos mínimos para executar o projecto)

1. Configure o Postgres e aplique o esquema (arquivo canónico em `server/migrations/init.sql`).
2. Execute o servidor Dart (padrão: `http://localhost:18080`).
3. Abra a app Flutter (`flutter run`) — o cliente usa `API_BASE_URL` (opcional) ou `http://localhost:18080` por omissão.

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
