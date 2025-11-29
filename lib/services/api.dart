import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class Api {
  // Base URL is configurable via .env (API_BASE_URL) or falls back to localhost:18080
  static String get baseUrl {
    try {
      return dotenv.env['API_BASE_URL'] ?? 'http://localhost:18080';
    } catch (_) {
      // dotenv not initialized yet — fall back to default
      return 'http://localhost:18080';
    }
  }

  static String? _apiKey;
  static Map<String, dynamic>? _currentUser;

  static void _attachAuthHeaders(Map<String, String> headers) {
    if (_apiKey != null) {
      headers['authorization'] = 'Bearer $_apiKey';
    }
  }

  static Future<List<Map<String, dynamic>>> getGames() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(Uri.parse('$baseUrl/games'), headers: headers);
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw Exception('Failed to load games: \\$res');
  }

  static Future<int> createGame(
    String course,
    DateTime date, {
    int? holes,
    String? status,
    List<Map<String, dynamic>>? players,
    String? mode,
    String? flow,
  }) async {
    final body = <String, dynamic>{
      'course': course,
      'date': date.toUtc().toIso8601String(),
    };
    if (holes != null) body['holes'] = holes;
    if (status != null) body['status'] = status;
    if (mode != null) body['mode'] = mode;
    if (flow != null) body['flow'] = flow;
    if (players != null) body['players'] = players;
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/games'),
      headers: headers,
      body: jsonEncode(body),
    );
    if (res.statusCode == 201) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['id'] as int;
    }
    throw Exception('Failed to create game: \\$res');
  }

  static Future<bool> deleteGame(int id) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.delete(
      Uri.parse('$baseUrl/games/$id'),
      headers: headers,
    );
    return res.statusCode == 200;
  }

  static Future<Map<String, dynamic>> addStroke(
    int gameId,
    String playerName,
    int holeNumber,
    int strokes, {
    int? roundId,
    bool overwrite = false,
  }) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final bodyMap = {
      'player_name': playerName,
      'hole_number': holeNumber,
      'strokes': strokes,
      'overwrite': overwrite,
    };
    if (roundId != null) bodyMap['round_id'] = roundId;
    final res = await http.post(
      Uri.parse('$baseUrl/games/$gameId/strokes'),
      headers: headers,
      body: jsonEncode(bodyMap),
    );
    if (res.statusCode != 201) {
      throw Exception('Failed to add stroke: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> createRound(int gameId) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/games/$gameId/rounds'),
      headers: headers,
      body: jsonEncode({}),
    );
    if (res.statusCode != 201) {
      throw Exception('Failed to create round: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> completeRound(
    int gameId,
    int roundId,
  ) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.patch(
      Uri.parse('$baseUrl/games/$gameId/rounds/$roundId/complete'),
      headers: headers,
      body: jsonEncode({}),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to complete round: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> finalizeGame(int gameId) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/games/$gameId/finalize'),
      headers: headers,
      body: jsonEncode({}),
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to finalize game: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<bool> addPlayer(int gameId, String playerName) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final body = jsonEncode({'player_name': playerName});
    final res = await http.post(
      Uri.parse('$baseUrl/games/$gameId/players'),
      headers: headers,
      body: body,
    );
    return res.statusCode == 201;
  }

  static WebSocketChannel wsForGame(int gameId) {
    // Build a proper websocket URI from the configured baseUrl.
    // This handles https/http, optional ports, and avoids issues when baseUrl
    // contains a path segment.
    final scheme = baseUrl.startsWith('https') ? 'wss' : 'ws';
    final parsed = Uri.parse(baseUrl);
    final host = parsed.host;
    final port = parsed.hasPort ? parsed.port : null;
    final path = '/ws/games/$gameId';
    final uri = Uri(scheme: scheme, host: host, port: port, path: path);
    return WebSocketChannel.connect(uri);
  }

  // Authentication helpers
  static Future<Map<String, dynamic>> login(
    String name,
    String password,
  ) async {
    final res = await http.post(
      Uri.parse('$baseUrl/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'name': name, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw Exception('Login failed: ${res.statusCode}');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    _apiKey = map['api_key'] as String?;
    _currentUser = (map['user'] as Map<dynamic, dynamic>?)?.map(
      (k, v) => MapEntry(k.toString(), v),
    );
    try {
      final box = Hive.box('auth');
      box.put('api_key', _apiKey);
      box.put('user', _currentUser);
    } catch (_) {}
    return _currentUser ?? {};
  }

  static Future<void> logout() async {
    _apiKey = null;
    _currentUser = null;
    try {
      final box = Hive.box('auth');
      await box.delete('api_key');
      await box.delete('user');
    } catch (_) {}
  }

  static Future<void> loadAuthFromStorage() async {
    try {
      if (!Hive.isBoxOpen('auth')) await Hive.openBox('auth');
      final box = Hive.box('auth');
      final key = box.get('api_key') as String?;
      final user = box.get('user') as Map?;
      if (key != null) _apiKey = key;
      if (user != null) _currentUser = Map<String, dynamic>.from(user);
    } catch (_) {}
  }

  static Map<String, dynamic>? currentUser() => _currentUser;

  static Future<List<Map<String, dynamic>>> listUsers() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(Uri.parse('$baseUrl/users'), headers: headers);
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw Exception('Failed to list users: ${res.statusCode}');
  }

  static Future<Map<String, dynamic>> createUser(
    String name,
    String password, {
    String role = 'viewer',
  }) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/users'),
      headers: headers,
      body: jsonEncode({'name': name, 'password': password, 'role': role}),
    );
    if (res.statusCode != 201) {
      throw Exception('Failed to create user: ${res.statusCode}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<String> revokeUser(int id) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/users/$id/revoke'),
      headers: headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to revoke user');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    return map['api_key'] as String;
  }

  // Admin: get auto-update status
  static Future<bool> getAutoUpdate() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(
      Uri.parse('$baseUrl/admin/auto_update'),
      headers: headers,
    );
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['enabled'] as bool? ?? false;
    }
    throw Exception('Failed to get auto-update status: ${res.statusCode}');
  }

  static Future<bool> setAutoUpdate(bool enabled) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/admin/auto_update'),
      headers: headers,
      body: jsonEncode({'enabled': enabled}),
    );
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['enabled'] as bool? ?? false;
    }
    throw Exception('Failed to set auto-update: ${res.statusCode}');
  }

  static Future<Map<String, dynamic>> getRound(int gameId, int roundId) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(
      Uri.parse('$baseUrl/games/$gameId/rounds/$roundId'),
      headers: headers,
    );
    if (res.statusCode != 200) {
      throw Exception('Failed to fetch round: ${res.statusCode} ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<List<Map<String, dynamic>>> getRounds(int gameId) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(
      Uri.parse('$baseUrl/games/$gameId/rounds'),
      headers: headers,
    );
    if (res.statusCode == 200) {
      final list = jsonDecode(res.body) as List<dynamic>;
      return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    throw Exception('Failed to list rounds: ${res.statusCode} ${res.body}');
  }
  
  static Future<Map<String, int>> getGameTotals(int gameId) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(
      Uri.parse('$baseUrl/games/$gameId/totals'),
      headers: headers,
    );
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final totalsRaw = (map['totals'] as Map?) ?? {};
      final totals = <String, int>{};
      totalsRaw.forEach((k, v) {
        totals[k.toString()] = (v as num).toInt();
      });
      return totals;
    }
    throw Exception('Failed to fetch game totals: ${res.statusCode} ${res.body}');
  }

  /// Fetch totals for multiple games in one call. Returns a map gameId -> (player -> total)
  static Future<Map<int, Map<String, int>>> getGamesTotals(List<int> gameIds) async {
    if (gameIds.isEmpty) return {};
    final ids = gameIds.join(',');
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(Uri.parse('$baseUrl/games/totals?ids=$ids'), headers: headers);
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final gamesRaw = (map['games'] as Map?) ?? {};
      final out = <int, Map<String, int>>{};
      gamesRaw.forEach((k, v) {
        final gid = int.tryParse(k.toString());
        if (gid == null) return;
        final totalsRaw = (v as Map?) ?? {};
        final totals = <String, int>{};
        totalsRaw.forEach((pk, pv) {
          totals[pk.toString()] = (pv as num).toInt();
        });
        out[gid] = totals;
      });
      return out;
    }
    throw Exception('Failed to fetch games totals: ${res.statusCode} ${res.body}');
  }

  // Admin: trigger an immediate update (git pull / pub get) — server will exit to allow restart
  static Future<Map<String, dynamic>> triggerUpdate() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(
      Uri.parse('$baseUrl/admin/trigger_update'),
      headers: headers,
      body: jsonEncode({}),
    );
    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to trigger update: ${res.statusCode}');
  }

  // Admin: fetch backend update.log contents
  static Future<String> getUpdateLog() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(
      Uri.parse('$baseUrl/admin/update_log'),
      headers: headers,
    );
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['log'] as String? ?? '';
    }
    throw Exception('Failed to fetch update log: ${res.statusCode}');
  }
}
