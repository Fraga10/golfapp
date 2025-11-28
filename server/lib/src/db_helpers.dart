import 'db.dart';

// Return canonical game state data (players map and totals) used by broadcasts
Future<Map<String, dynamic>> fetchCanonicalGameState(int gid) async {
  final rows = await DB.conn.query(
    'SELECT player_name, hole_number, SUM(strokes) as strokes_sum FROM strokes WHERE game_id = @gid GROUP BY player_name, hole_number',
    substitutionValues: {'gid': gid},
  );
  final Map<String, Map<String, int>> players = {};
  final Map<String, int> totals = {};
  for (final r in rows) {
    final pname = r[0] as String;
    final hole = (r[1] as int);
    final ssum = (r[2] as int?) ?? 0;
    players.putIfAbsent(pname, () => {})[hole.toString()] = ssum;
    totals[pname] = (totals[pname] ?? 0) + ssum;
  }
  return {'players': players, 'totals': totals};
}

// Fetch detailed strokes for a specific round: per-player per-hole breakdown and totals
Future<Map<String, dynamic>> fetchRoundDetails(int roundId) async {
  final rows = await DB.conn.query(
    'SELECT player_name, hole_number, SUM(strokes) as strokes_sum FROM strokes WHERE round_id = @rid GROUP BY player_name, hole_number',
    substitutionValues: {'rid': roundId},
  );
  final Map<String, Map<String, int>> players = {};
  final Map<String, int> totals = {};
  for (final r in rows) {
    final pname = r[0] as String;
    final hole = (r[1] as int);
    final ssum = (r[2] as int?) ?? 0;
    players.putIfAbsent(pname, () => {})[hole.toString()] = ssum;
    totals[pname] = (totals[pname] ?? 0) + ssum;
  }
  return {'players': players, 'totals': totals};
}

// Fetch totals for a specific round
Future<Map<String, int>> fetchRoundTotals(int roundId) async {
  final rows = await DB.conn.query('SELECT player_name, SUM(strokes) FROM strokes WHERE round_id = @rid GROUP BY player_name', substitutionValues: {'rid': roundId});
  final Map<String, int> totals = {};
  for (final r in rows) {
    totals[r[0] as String] = (r[1] as int?) ?? 0;
  }
  return totals;
}

// Fetch totals across a game (all strokes grouped by player)
Future<Map<String, int>> fetchGameTotals(int gid) async {
  final rows = await DB.conn.query('SELECT player_name, SUM(strokes) as total FROM strokes WHERE game_id = @gid GROUP BY player_name', substitutionValues: {'gid': gid});
  final Map<String, int> totals = {};
  for (final r in rows) {
    totals[r[0] as String] = (r[1] as int?) ?? 0;
  }
  return totals;
}
