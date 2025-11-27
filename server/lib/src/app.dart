import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'db.dart';

final Map<int, Set<WebSocketChannel>> _gameSockets = {};

Handler createHandler() {
  final router = Router();

  // Helper: extract API key from Authorization header and return user row
  Future<Map<String, dynamic>?> userFromRequest(Request req) async {
    final auth = req.headers['authorization'];
    if (auth == null || !auth.toLowerCase().startsWith('bearer ')) return null;
    final token = auth.substring(7).trim();
    if (token.isEmpty) return null;
    final res = await DB.conn.query('SELECT id, name, api_key, role FROM users WHERE api_key = @k', substitutionValues: {'k': token});
    if (res.isEmpty) return null;
    final row = res.first;
    return {
      'id': row[0],
      'name': row[1],
      'api_key': row[2],
      'role': row[3],
    };
  }

  String randomToken([int length = 32]) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }
  // fallback hash (not used when PBKDF2 is applied)
  String hash(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // PBKDF2-HMAC-SHA256 implementation returning hex digest
  String pbkdf20(String password, String salt, int iterations, int dkLen) {
    final pbkdf2 = Hmac(sha256, utf8.encode(password));
    List<int> F(List<int> saltBytes, int blockIndex) {
      // U1 = HMAC(password, salt || INT(blockIndex))
      final block = <int>[...saltBytes];
      block.addAll([ (blockIndex >> 24) & 0xff, (blockIndex >> 16) & 0xff, (blockIndex >> 8) & 0xff, blockIndex & 0xff ]);
      List<int> u = pbkdf2.convert(block).bytes;
      final out = List<int>.from(u);
      for (var i = 1; i < iterations; i++) {
        u = pbkdf2.convert(u).bytes;
        for (var j = 0; j < out.length; j++) {
          out[j] ^= u[j];
        }
      }
      return out;
    }

    final saltBytes = utf8.encode(salt);
    final blocks = (dkLen + 31) ~/ 32;
    final out = <int>[];
    for (var i = 1; i <= blocks; i++) {
      out.addAll(F(saltBytes, i));
    }
    final derived = out.sublist(0, dkLen);
    return derived.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  String makePasswordHash(String password) {
    final rnd = Random.secure();
    final saltBytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    final salt = base64Url.encode(saltBytes);
    final iterations = 10000;
    final dk = pbkdf20(password, salt, iterations, 32);
    return 'pbkdf2\$$iterations\$$salt\$$dk';
  }

  bool verifyPassword(String password, String stored) {
    try {
      if (!stored.startsWith('pbkdf2\$')) return false;
      final parts = stored.split('\$');
      if (parts.length != 4) return false;
      final iterations = int.parse(parts[1]);
      final salt = parts[2];
      final expected = parts[3];
      final dk = pbkdf20(password, salt, iterations, expected.length ~/ 2);
      return dk == expected;
    } catch (_) {
      return false;
    }
  }

  router.get('/health', (Request req) => Response.ok(jsonEncode({'ok': true}), headers: {'content-type': 'application/json'}));

  // Temporary debug endpoint
  router.get('/ping', (Request req) => Response.ok('pong', headers: {'content-type': 'text/plain'}));

  router.get('/games', (Request req) async {
    final res = await DB.conn.query('SELECT id, course, date, holes, status, created_at FROM games ORDER BY id DESC');
    final games = res.map((row) {
      return {
        'id': row[0],
        'course': row[1],
        'date': (row[2] as DateTime).toIso8601String(),
        'holes': row[3],
        'status': row[4],
      };
    }).toList();
    return Response.ok(jsonEncode(games), headers: {'content-type': 'application/json'});
  });

  router.get('/games/<id|[0-9]+>', (Request req, String id) async {
    final res = await DB.conn.query('SELECT id, course, date, holes, status, created_at FROM games WHERE id = @id', substitutionValues: {'id': int.parse(id)});
    if (res.isEmpty) return Response.notFound('Game not found');
    final row = res.first;
    final game = {
      'id': row[0],
      'course': row[1],
      'date': (row[2] as DateTime).toIso8601String(),
      'holes': row[3],
      'status': row[4],
    };
    return Response.ok(jsonEncode(game), headers: {'content-type': 'application/json'});
  });

  router.post('/games', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final course = body['course'] as String? ?? 'Unknown';
    final date = body['date'] as String? ?? DateTime.now().toIso8601String();
    final holes = body['holes'] ?? 18;
    final status = body['status'] as String? ?? 'pending';

    final res = await DB.conn.query(
      'INSERT INTO games (course, date, holes, status) VALUES (@course, @date, @holes, @status) RETURNING id',
      substitutionValues: {'course': course, 'date': DateTime.parse(date), 'holes': holes, 'status': status},
    );
    final id = res.first[0] as int;

    // optional players list to pre-populate players for past games
    if (body.containsKey('players')) {
      final players = body['players'];
      if (players is List) {
        for (final p in players) {
          if (p is Map && p.containsKey('player_name')) {
            await DB.conn.query('INSERT INTO game_players (game_id, player_name) VALUES (@gid, @pname)', substitutionValues: {'gid': id, 'pname': p['player_name']});
            // optionally accept per-hole strokes map
            if (p.containsKey('strokes') && p['strokes'] is Map) {
              final strokesMap = p['strokes'] as Map;
              for (final entry in strokesMap.entries) {
                final hole = int.tryParse(entry.key.toString()) ?? 0;
                final strokes = (entry.value as num).toInt();
                if (hole > 0) {
                  await DB.conn.query('INSERT INTO strokes (game_id, player_name, hole_number, strokes) VALUES (@gid, @pname, @hole, @strokes)', substitutionValues: {'gid': id, 'pname': p['player_name'], 'hole': hole, 'strokes': strokes});
                }
              }
            }
          } else if (p is String) {
            await DB.conn.query('INSERT INTO game_players (game_id, player_name) VALUES (@gid, @pname)', substitutionValues: {'gid': id, 'pname': p});
          }
        }
      }
    }

    return Response(201, body: jsonEncode({'id': id}), headers: {'content-type': 'application/json'});
  });

  // Register new user. If this is the first user (no users yet) allow creating with any role (becomes admin).
  router.post('/register', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final name = (body['name'] as String?)?.trim();
    final password = body['password'] as String?;
    var role = (body['role'] as String?)?.trim();
    if (name == null || name.isEmpty || password == null || password.isEmpty) {
      return Response(400, body: 'Missing name or password');
    }
    // Ensure columns exist (safe to call repeatedly)
    await DB.conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT");
    await DB.conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'viewer'");

    final countRes = await DB.conn.query('SELECT count(*) FROM users');
    final count = (countRes.first[0] as int?) ?? 0;
    if (count == 0) {
      // first user becomes admin if role provided as 'admin' or any
      role = role ?? 'admin';
    } else {
      // require admin auth to create additional users
      final requester = await userFromRequest(req);
      if (requester == null || requester['role'] != 'admin') {
        return Response.forbidden('Requires admin to create users');
      }
      role = role ?? 'viewer';
    }

    final apiKey = randomToken();
    final passHash = makePasswordHash(password);
    final res = await DB.conn.query(
      'INSERT INTO users (name, api_key, password_hash, role) VALUES (@name, @api, @ph, @role) RETURNING id',
      substitutionValues: {'name': name, 'api': apiKey, 'ph': passHash, 'role': role},
    );
    final id = res.first[0] as int;
    return Response(201, body: jsonEncode({'id': id, 'api_key': apiKey, 'role': role}), headers: {'content-type': 'application/json'});
  });

  // Login: returns api_key and user info
  router.post('/login', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final name = (body['name'] as String?)?.trim();
    final password = body['password'] as String?;
    if (name == null || password == null) return Response(400, body: 'Missing name/password');
    // ensure column exists
    await DB.conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT");
    await DB.conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'viewer'");

    final res = await DB.conn.query('SELECT id, name, api_key, password_hash, role FROM users WHERE name = @name', substitutionValues: {'name': name});
    if (res.isEmpty) return Response.forbidden('Invalid credentials');
    final row = res.first;
    final storedHash = row[3] as String?;
    if (storedHash == null || storedHash.isEmpty) return Response(400, body: 'User has no password set');
    final ok = verifyPassword(password, storedHash);
    if (!ok) return Response.forbidden('Invalid credentials');
    final user = {'id': row[0], 'name': row[1], 'api_key': row[2], 'role': row[4]};
    return Response.ok(jsonEncode({'api_key': row[2], 'user': user}), headers: {'content-type': 'application/json'});
  });

  // Admin: list users
  router.get('/users', (Request req) async {
    final user = await userFromRequest(req);
    if (user == null || user['role'] != 'admin') return Response.forbidden('Requires admin');
    final res = await DB.conn.query('SELECT id, name, role, api_key FROM users ORDER BY id');
    final list = res.map((r) => {'id': r[0], 'name': r[1], 'role': r[2], 'api_key': r[3]}).toList();
    return Response.ok(jsonEncode(list), headers: {'content-type': 'application/json'});
  });

  // Admin: create user (alternate endpoint to register; requires admin)
  router.post('/users', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') return Response.forbidden('Requires admin');
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final name = (body['name'] as String?)?.trim();
    final password = body['password'] as String?;
    final role = (body['role'] as String?) ?? 'viewer';
    if (name == null || name.isEmpty || password == null || password.isEmpty) return Response(400, body: 'Missing name or password');
    final apiKey = randomToken();
    final passHash = makePasswordHash(password);
    final res = await DB.conn.query('INSERT INTO users (name, api_key, password_hash, role) VALUES (@name, @api, @ph, @role) RETURNING id', substitutionValues: {'name': name, 'api': apiKey, 'ph': passHash, 'role': role});
    final id = res.first[0] as int;
    return Response(201, body: jsonEncode({'id': id, 'api_key': apiKey, 'role': role}), headers: {'content-type': 'application/json'});
  });

  // Admin: update user role
  router.patch('/users/<id|[0-9]+>', (Request req, String id) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') return Response.forbidden('Requires admin');
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final updates = <String>[];
    final values = <String, dynamic>{'id': int.parse(id)};
    if (body.containsKey('role')) {
      updates.add('role = @role');
      values['role'] = body['role'];
    }
    if (updates.isEmpty) return Response(400, body: 'Nothing to update');
    final sql = 'UPDATE users SET ${updates.join(', ')} WHERE id = @id';
    await DB.conn.query(sql, substitutionValues: values);
    return Response.ok(jsonEncode({'ok': true}), headers: {'content-type': 'application/json'});
  });

  // Admin: revoke/regenerate api key for a user
  router.post('/users/<id|[0-9]+>/revoke', (Request req, String id) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') return Response.forbidden('Requires admin');
    final newKey = randomToken();
    await DB.conn.query('UPDATE users SET api_key = @k WHERE id = @id', substitutionValues: {'k': newKey, 'id': int.parse(id)});
    return Response.ok(jsonEncode({'api_key': newKey}), headers: {'content-type': 'application/json'});
  });

  router.patch('/games/<id|[0-9]+>', (Request req, String id) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final updates = <String>[];
    final values = <String, dynamic>{'id': int.parse(id)};
    if (body.containsKey('status')) {
      updates.add('status = @status');
      values['status'] = body['status'];
    }
    if (updates.isEmpty) return Response(400, body: 'Nothing to update');
    final sql = 'UPDATE games SET ${updates.join(', ')} WHERE id = @id';
    await DB.conn.query(sql, substitutionValues: values);
    return Response.ok(jsonEncode({'ok': true}), headers: {'content-type': 'application/json'});
  });

  router.post('/games/<id|[0-9]+>/strokes', (Request req, String id) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final playerName = body['player_name'] as String? ?? 'Player';
    final holeNumber = body['hole_number'] as int? ?? 1;
    final strokes = body['strokes'] as int? ?? 1;
    final overwrite = body['overwrite'] as bool? ?? false;
    final gid = int.parse(id);
    final user = await userFromRequest(req);
    if (user == null) return Response.forbidden('Authentication required');
    final role = (user['role'] as String?) ?? 'viewer';
    // viewers cannot post strokes
    if (role == 'viewer') return Response.forbidden('Insufficient permissions');
    // players can only post strokes for themselves
    if (role == 'player' && (user['name'] as String) != playerName) {
      return Response.forbidden('Players may only post strokes for themselves');
    }
    if (overwrite) {
      await DB.conn.transaction((ctx) async {
        await ctx.query('DELETE FROM strokes WHERE game_id = @gid AND player_name = @player AND hole_number = @hole', substitutionValues: {'gid': gid, 'player': playerName, 'hole': holeNumber});
        await ctx.query('INSERT INTO strokes (game_id, player_name, hole_number, strokes) VALUES (@gameId, @player, @hole, @strokes)', substitutionValues: {'gameId': gid, 'player': playerName, 'hole': holeNumber, 'strokes': strokes});
      });
    } else {
      await DB.conn.query('INSERT INTO strokes (game_id, player_name, hole_number, strokes) VALUES (@gameId, @player, @hole, @strokes)', substitutionValues: {'gameId': gid, 'player': playerName, 'hole': holeNumber, 'strokes': strokes});
    }

    // Broadcast to websockets listeners of this game
    final payload = jsonEncode({
      'type': 'stroke',
      'game_id': gid,
      'player_name': playerName,
      'hole_number': holeNumber,
      'strokes': strokes,
      'ts': DateTime.now().toIso8601String(),
      'overwrite': overwrite,
    });
    final sockets = _gameSockets[gid];
    if (sockets != null) {
      for (final s in sockets) {
        try {
          s.sink.add(payload);
        } catch (_) {}
      }
    }

    return Response(201, body: jsonEncode({'ok': true}), headers: {'content-type': 'application/json'});
  });

  // Delete game and its strokes
  router.delete('/games/<id|[0-9]+>', (Request req, String id) async {
    final user = await userFromRequest(req);
    if (user == null) return Response.forbidden('Authentication required');
    final role = (user['role'] as String?) ?? 'viewer';
    if (role != 'admin' && role != 'editor') return Response.forbidden('Requires admin/editor');
    final gid = int.parse(id);
    await DB.conn.transaction((ctx) async {
      await ctx.query('DELETE FROM strokes WHERE game_id = @gid', substitutionValues: {'gid': gid});
      await ctx.query('DELETE FROM games WHERE id = @gid', substitutionValues: {'gid': gid});
    });
    // notify websockets (close them)
    final sockets = _gameSockets.remove(gid);
    if (sockets != null) {
      for (final s in sockets) {
        try {
          s.sink.add(jsonEncode({'type': 'game_closed', 'game_id': gid}));
          s.sink.close();
        } catch (_) {}
      }
    }
    return Response.ok(jsonEncode({'ok': true}), headers: {'content-type': 'application/json'});
  });

  // WebSocket endpoint for live updates per game
  router.get('/ws/games/<id|[0-9]+>', webSocketHandler((webSocket, req) {
    final idStr = req.params['id']!;
    final gid = int.parse(idStr);
    _gameSockets.putIfAbsent(gid, () => <WebSocketChannel>{}).add(webSocket);
    webSocket.stream.listen((message) {
      // For now, just ignore incoming messages or could be used for commands
    }, onDone: () {
      _gameSockets[gid]?.remove(webSocket);
    });
  }));

  // Admin: trigger hot-reload for all connected clients (broadcast)
  router.post('/admin/hotreload', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') return Response.forbidden('Requires admin');
    final payload = jsonEncode({'type': 'hot_reload', 'ts': DateTime.now().toIso8601String()});
    for (final sockets in _gameSockets.values) {
      for (final s in sockets) {
        try {
          s.sink.add(payload);
        } catch (_) {}
      }
    }
    return Response.ok(jsonEncode({'ok': true}), headers: {'content-type': 'application/json'});
  });

  return router.call;
}
