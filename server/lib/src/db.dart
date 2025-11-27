import 'dart:io';
import 'package:postgres/postgres.dart';

class DB {
  static late PostgreSQLConnection _conn;

  static Future<void> init() async {
    // Load environment variables from .env if present, otherwise use system env
    final env = <String, String>{}..addAll(Platform.environment);
    final file = File('.env');
    if (file.existsSync()) {
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final idx = trimmed.indexOf('=');
        if (idx <= 0) continue;
        final key = trimmed.substring(0, idx).trim();
        final value = trimmed.substring(idx + 1).trim();
        env[key] = value;
      }
    }

    final host = env['DB_HOST'] ?? '192.168.1.101';
    final port = int.tryParse(env['DB_PORT'] ?? '5432') ?? 5432;
    final db = env['DB_NAME'] ?? 'golfe_db';
    final user = env['DB_USER'] ?? 'golfe_user';
    final pass = env['DB_PASS'] ?? 'golfepass';

    _conn = PostgreSQLConnection(host, port, db, username: user, password: pass);
    await _conn.open();
  }

  static PostgreSQLConnection get conn => _conn;
}
