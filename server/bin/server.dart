import 'dart:io';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf/shelf.dart';

import 'package:golfe_server/src/db.dart';
import 'package:golfe_server/src/app.dart';

Future<void> main(List<String> args) async {
  // server/.env is read by DB.init; read PORT from .env or environment
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
  final port = int.tryParse(env['PORT'] ?? '8080') ?? 8080;

  await DB.init();

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(createHandler());

  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('Server listening on port ${server.port}');
}
