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
    final users = await DB.conn.query("SELECT column_name FROM information_schema.columns WHERE table_name='users'");
    stderr.writeln('users columns: ${users.map((r) => r[0]).toList()}');
    final games = await DB.conn.query("SELECT column_name FROM information_schema.columns WHERE table_name='games'");
    stderr.writeln('games columns: ${games.map((r) => r[0]).toList()}');
    final players = await DB.conn.query("SELECT column_name FROM information_schema.columns WHERE table_name='game_players'");
    stderr.writeln('game_players columns: ${players.map((r) => r[0]).toList()}');
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
