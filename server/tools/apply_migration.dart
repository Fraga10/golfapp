import 'dart:io';
import 'package:golfe_server/src/db.dart';

Future<void> main(List<String> args) async {
  final path = args.isNotEmpty ? args[0] : 'migrations/20251127_add_rounds.sql';
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('Migration file not found: ${file.path}');
    exit(2);
  }
  stderr.writeln('Using migration file: ${file.path}');

  try {
    await DB.init();
  } catch (e, st) {
    stderr.writeln('Failed to initialize DB connection: $e');
    stderr.writeln(st.toString());
    exit(3);
  }

  final sql = file.readAsStringSync();
  try {
    await DB.conn.transaction((ctx) async {
      // Execute the SQL in the file. This may contain multiple statements.
      await ctx.execute(sql);
    });
    stderr.writeln('Migration applied successfully.');
  } catch (e, st) {
    stderr.writeln('Error applying migration: $e');
    stderr.writeln(st.toString());
    exit(4);
  } finally {
    try {
      await DB.conn.close();
    } catch (_) {}
  }
}
