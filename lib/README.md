# Client (lib) — golfe (Flutter)

Resumo
- Cliente Flutter com UI de jogo ao vivo.
- Comunicação com backend via HTTP (`lib/services/api.dart`) e WebSocket para sincronização em tempo-real.
- Usa `Hive` para cache local (`live_cache`, `auth`) — não há persistência de debug por omissão.

Pré-requisitos
- Flutter SDK (compatível com o projeto).
- Em desenvolvimento, configurar `API_BASE_URL` (opcional) ou usar `http://localhost:18080`.

Arquivos principais
- `lib/main.dart` — ponto de entrada da app.
- `lib/services/api.dart` — cliente HTTP e WebSocket helpers. Notas:
  - `baseUrl` é configurável via `.env` (`API_BASE_URL`) ou usa `http://localhost:18080` por omissão.
  - Métodos relevantes: `addStroke`, `createRound`, `completeRound`, `getRound`, `wsForGame`.
- `lib/screens/live_game.dart` — UI de jogo ao vivo:
  - Gera eventos de `stroke` e aplica atualizações locais enquanto aguarda o `game_state` canónico do servidor.
  - Usa Hive box `live_cache` para armazenar estado local (scores, rounds cache).

Fluxo de rounds (Pitch & Putt)
- Rounds do tipo Pitch & Putt usam 3 buracos (1..3).
- O cliente envia `round_id` ao inserir strokes quando disponível; o servidor pode também criar um round automaticamente na primeira tacada.
- O servidor broadcasta `stroke` e `game_state` via WebSocket para sincronizar clientes.

Executar a app (desenvolvimento)
```powershell
# na raiz do repo
flutter pub get
flutter run
```

Configuração local/hive
- Hive boxes usados:
  - `auth` — armazena `api_key` e `user` quando o utilizador faz login.
  - `live_cache` — cache local de pontuações e rounds.

Depuração
- Para verificar se o cliente está a comunicar com o servidor, confirme `API_BASE_URL` e que o servidor escuta em `http://localhost:18080`.
- Healthcheck do servidor:
```powershell
Invoke-RestMethod -Uri http://localhost:18080/health -Method GET
```

Notas de desenvolvimento
- As funcionalidades de debug temporárias (boxes `debug_strokes` / debug UI) foram removidas para restaurar o comportamento anterior.
- Se for necessário capturar temporariamente payloads para diagnóstico, crie handlers que escrevam para a consola em vez de persistir no dispositivo do utilizador.

Contribuição
- Ao alterar os endpoints consumidos por `lib/services/api.dart`, actualize este ficheiro e o README do servidor.
