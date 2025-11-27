import 'dart:io';
import 'package:golfe_server/src/db.dart';

Future<void> main(List<String> args) async {
  try {
    await DB.init();
  } catch (e, st) {
    stderr.writeln('DB init failed: $e');
    stderr.writeln(st.toString());
    exit(2);
  }

  try {
    final rounds = await DB.conn.query("SELECT column_name FROM information_schema.columns WHERE table_name='rounds'");
    stderr.writeln('rounds columns: ${rounds.map((r) => r[0]).toList()}');
    final strokes = await DB.conn.query("SELECT column_name FROM information_schema.columns WHERE table_name='strokes'");
    stderr.writeln('strokes columns: ${strokes.map((r) => r[0]).toList()}');
  } catch (e, st) {
    stderr.writeln('Query failed: $e');
    stderr.writeln(st.toString());
    exit(3);
  } finally {
    try { await DB.conn.close(); } catch (_) {}
  }
}
