import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hive_flutter/hive_flutter.dart';

class Api {
  // Update this base URL if your server is remote or uses TLS
  static const baseUrl = 'http://localhost:18080';
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

  static Future<int> createGame(String course, DateTime date, {int? holes, String? status, List<Map<String, dynamic>>? players}) async {
    final body = <String, dynamic>{'course': course, 'date': date.toUtc().toIso8601String()};
    if (holes != null) body['holes'] = holes;
    if (status != null) body['status'] = status;
    if (players != null) body['players'] = players;
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(Uri.parse('$baseUrl/games'), headers: headers, body: jsonEncode(body));
    if (res.statusCode == 201) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['id'] as int;
    }
    throw Exception('Failed to create game: \\$res');
  }

  static Future<bool> deleteGame(int id) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.delete(Uri.parse('$baseUrl/games/$id'), headers: headers);
    return res.statusCode == 200;
  }

  static Future<Map<String, dynamic>> addStroke(int gameId, String playerName, int holeNumber, int strokes, {bool overwrite = false}) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final body = jsonEncode({'player_name': playerName, 'hole_number': holeNumber, 'strokes': strokes, 'overwrite': overwrite});
    final res = await http.post(Uri.parse('$baseUrl/games/$gameId/strokes'), headers: headers, body: body);
    if (res.statusCode != 201) {
      throw Exception('Failed to add stroke: \\$res');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static WebSocketChannel wsForGame(int gameId) {
    // Connect to ws endpoint; on production use wss and a proper host
      final scheme = baseUrl.startsWith('https') ? 'wss' : 'ws';
      final host = baseUrl.replaceFirst(RegExp(r'^https?://'), '');
      final uri = Uri.parse('$scheme://$host/ws/games/$gameId');
    return WebSocketChannel.connect(uri);
  }

  // Authentication helpers
  static Future<Map<String, dynamic>> login(String name, String password) async {
    final res = await http.post(Uri.parse('$baseUrl/login'), headers: {'content-type': 'application/json'}, body: jsonEncode({'name': name, 'password': password}));
    if (res.statusCode != 200) throw Exception('Login failed: ${res.statusCode}');
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    _apiKey = map['api_key'] as String?;
    _currentUser = (map['user'] as Map<dynamic, dynamic>?)?.map((k, v) => MapEntry(k.toString(), v));
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

  static void loadAuthFromStorage() {
    try {
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

  static Future<Map<String, dynamic>> createUser(String name, String password, {String role = 'viewer'}) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(Uri.parse('$baseUrl/users'), headers: headers, body: jsonEncode({'name': name, 'password': password, 'role': role}));
    if (res.statusCode != 201) throw Exception('Failed to create user: ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  static Future<String> revokeUser(int id) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(Uri.parse('$baseUrl/users/$id/revoke'), headers: headers);
    if (res.statusCode != 200) throw Exception('Failed to revoke user');
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    return map['api_key'] as String;
  }

  // Admin: get auto-update status
  static Future<bool> getAutoUpdate() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(Uri.parse('$baseUrl/admin/auto_update'), headers: headers);
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['enabled'] as bool? ?? false;
    }
    throw Exception('Failed to get auto-update status: ${res.statusCode}');
  }

  static Future<bool> setAutoUpdate(bool enabled) async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(Uri.parse('$baseUrl/admin/auto_update'), headers: headers, body: jsonEncode({'enabled': enabled}));
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['enabled'] as bool? ?? false;
    }
    throw Exception('Failed to set auto-update: ${res.statusCode}');
  }

  // Admin: trigger an immediate update (git pull / pub get) ÔÇö server will exit to allow restart
  static Future<Map<String, dynamic>> triggerUpdate() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.post(Uri.parse('$baseUrl/admin/trigger_update'), headers: headers, body: jsonEncode({}));
    if (res.statusCode == 200) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Failed to trigger update: ${res.statusCode}');
  }

  // Admin: fetch backend update.log contents
  static Future<String> getUpdateLog() async {
    final headers = <String, String>{'content-type': 'application/json'};
    _attachAuthHeaders(headers);
    final res = await http.get(Uri.parse('$baseUrl/admin/update_log'), headers: headers);
    if (res.statusCode == 200) {
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      return map['log'] as String? ?? '';
    }
    throw Exception('Failed to fetch update log: ${res.statusCode}');
  }
}
