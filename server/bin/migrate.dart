import 'dart:io';
import 'package:golfe_server/src/db.dart';

Future<void> main(List<String> args) async {
  final sqlPath = 'migrations/init.sql';
  final sql = await File(sqlPath).readAsString();

  await DB.init();

  // Split by ; and execute statements individually
  final statements = sql.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  for (final stmt in statements) {
    try {
      await DB.conn.execute(stmt);
      print('Executed statement');
    } catch (e) {
      print('Error executing statement: $e');
    }
  }

  print('Migrations complete.');
  await DB.conn.close();
}
