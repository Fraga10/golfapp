# golfe

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Database migrations (server)

This project uses a consolidated SQL schema in `server/migrations/init.sql` and provides simple Dart tooling to apply and check the schema against your Postgres database.

- **Apply the schema (default)** — runs `migrations/init.sql` by default:

```powershell
cd 'c:\Users\rodri\OneDrive\Ambiente de Trabalho\APPs\golfe\server'
dart pub get
dart run tools/apply_migration.dart
```

- **Apply a specific migration file** (if needed):

```powershell
dart run tools/apply_migration.dart migrations/20251127_add_rounds.sql
```

- **Check schema** — lists the important tables/columns (users, games, game_players, rounds, strokes):

```powershell
dart run tools/check_migration.dart
```

Notes:
- `tools/apply_migration.dart` will default to `migrations/init.sql` when no path is provided.
- `migrations/init.sql` is the canonical consolidated schema (it contains `games.mode`, the `rounds` table and `strokes.round_id`).
- If your DB credentials are different, edit `server/.env` so the migration tools connect to the correct Postgres instance.

If you prefer to keep separate migration files, you can still run them individually with `tools/apply_migration.dart <path>`; this repo currently keeps a single consolidated `init.sql` for simplicity.

### Repo workflow note (please follow)

- Quando adicionarmos uma nova *feature* que altera a API ou o comportamento, atualize o `README.md` com uma breve nota explicando a funcionalidade e como testá-la.
- Quando consolidarmos o esquema numa `init.sql`, remova os ficheiros de migration SQL individuais que já não são usados (por exemplo `20251127_add_rounds.sql`) para evitar confusão.
- Use `tools/check_migration.dart` para validar o esquema após aplicar migrations.

Seguindo estas regras mantemos o repositório limpo e a documentação atualizada.
