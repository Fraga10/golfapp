import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'db.dart';
import 'auth_helpers.dart';
import 'db_helpers.dart';

final Map<int, Set<WebSocketChannel>> _gameSockets = {};
final Set<WebSocketChannel> _adminSockets = {};

Handler createHandler() {
  final router = Router();

  // Middleware: respect X-Forwarded-* or Forwarded headers from proxies/tunnels.
  // If the tunnel/proxy provides a public host/proto, rewrite the Host header
  // on the Request so downstream components (and any router redirects) use
  // the public hostname instead of the origin internal IP.
  FutureOr<Response> _forwardingWrapper(Request req) async {
    try {
      final headers = Map<String, String>.from(req.headers);
      String? forwarded = headers['forwarded'];
      String? xfh = headers['x-forwarded-host'];
      String? xfp = headers['x-forwarded-proto'];

      // Parse `Forwarded: for=...; proto=https; host=apigolf.rgfapp.com` if present
      if ((xfh == null || xfh.isEmpty) && forwarded != null && forwarded.isNotEmpty) {
        try {
          final parts = forwarded.split(RegExp(r';\s*'));
          for (final p in parts) {
            final kv = p.split('=');
            if (kv.length == 2) {
              final k = kv[0].trim();
              final v = kv[1].trim();
              if (k.toLowerCase() == 'host') xfh = v;
              if (k.toLowerCase() == 'proto') xfp = v;
            }
          }
        } catch (_) {}
      }

      if (xfh != null && xfh.isNotEmpty) {
        headers['host'] = xfh;
        // Also ensure the scheme header is present for any downstream logic
        if (xfp != null && xfp.isNotEmpty) headers['x-forwarded-proto'] = xfp;
        final changed = req.change(headers: headers);
        return await router.call(changed);
      }
    } catch (_) {}
    return await router.call(req);
  }

  // Self-update / watcher state
  bool autoUpdateEnabled = false;
  bool updateInProgress = false;
  DateTime lastObserved = DateTime.now();
  DateTime? lastUpdateStarted;
  String lastUpdateStatus = 'idle';
  String? lastUpdateMessage;

  final File autoFile = File('.autoupdate');
  if (autoFile.existsSync()) {
    try {
      final content = autoFile.readAsStringSync().trim();
      autoUpdateEnabled = content.toLowerCase() == 'true';
    } catch (_) {}
  }

  void saveAutoUpdate(bool v) {
    autoUpdateEnabled = v;
    try {
      autoFile.writeAsStringSync(v ? 'true' : 'false');
    } catch (_) {}
  }

  Future<DateTime> latestSourceMTime(Directory dir) async {
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final path = entity.path;
          if (path.endsWith('.dart') ||
              path.endsWith('.yaml') ||
              path.endsWith('.pubspec')) {
            try {
              final stat = await entity.stat();
              if (stat.modified.isAfter(latest)) latest = stat.modified;
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return latest;
  }

  Future<void> performUpdate() async {
    if (updateInProgress) return;
    updateInProgress = true;
    try {
      // Run update steps and log output. Do NOT exit the process.
      final log = File('update.log');
      void append(String s) {
        try {
          log.writeAsStringSync('$s\n', mode: FileMode.append);
        } catch (_) {}
      }

      lastUpdateStarted = DateTime.now();
      lastUpdateStatus = 'running';
      lastUpdateMessage = null;
      append('=== Update started: ${lastUpdateStarted!.toIso8601String()} ===');
      // notify admin websockets that update started
      try {
        final notice = jsonEncode({
          'type': 'update_status',
          'status': 'running',
          'started': lastUpdateStarted!.toIso8601String()
        });
        for (final s in _adminSockets) {
          try {
            s.sink.add(notice);
          } catch (_) {}
        }
      } catch (_) {}
      try {
        final gitCheck =
            await Process.run('git', ['rev-parse', '--is-inside-work-tree']);
        append('git check exit=${gitCheck.exitCode}');
        append(gitCheck.stdout?.toString() ?? '');
        append(gitCheck.stderr?.toString() ?? '');
        if (gitCheck.exitCode == 0) {
          final gitPull = await Process.run('git', ['pull']);
          append('git pull exit=${gitPull.exitCode}');
          append(gitPull.stdout?.toString() ?? '');
          append(gitPull.stderr?.toString() ?? '');
        } else {
          append('not a git repository');
        }
      } catch (e) {
        append('git error: $e');
      }
      try {
        final pubGet = await Process.run('dart', ['pub', 'get']);
        append('pub get exit=${pubGet.exitCode}');
        append(pubGet.stdout?.toString() ?? '');
        append(pubGet.stderr?.toString() ?? '');
      } catch (e) {
        append('pub get error: $e');
      }
      append('=== Update finished; process continues (no restart) ===');
      lastUpdateStatus = 'finished';
      lastUpdateMessage =
          'Update finished; no automatic restart performed. Check update.log for details.';
      // notify admin websockets that update finished
      try {
        final notice = jsonEncode({
          'type': 'update_status',
          'status': 'finished',
          'started': lastUpdateStarted?.toIso8601String(),
          'message': lastUpdateMessage,
          'ts': DateTime.now().toIso8601String()
        });
        for (final s in _adminSockets) {
          try {
            s.sink.add(notice);
          } catch (_) {}
        }
      } catch (_) {}
      // small delay to flush logs
      await Future.delayed(Duration(milliseconds: 200));
    } finally {
      updateInProgress = false;
    }
  }

  // start a lightweight watcher that checks for changes every 5 seconds
  Timer.periodic(Duration(seconds: 5), (t) async {
    if (!autoUpdateEnabled || updateInProgress) return;
    final dir = Directory.current;
    final latest = await latestSourceMTime(dir);
    if (latest.isAfter(lastObserved)) {
      lastObserved = latest;
      // perform update
      await performUpdate();
    }
  });

  // note: authentication helpers moved to `auth_helpers.dart`

  String randomToken([int length = 32]) {
    final rnd = Random.secure();
    final bytes = List<int>.generate(length, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes);
  }
  // (removed unused fallback hash)

  // PBKDF2-HMAC-SHA256 implementation returning hex digest
  String pbkdf20(String password, String salt, int iterations, int dkLen) {
    final pbkdf2 = Hmac(sha256, utf8.encode(password));
    List<int> F(List<int> saltBytes, int blockIndex) {
      // U1 = HMAC(password, salt || INT(blockIndex))
      final block = <int>[...saltBytes];
      block.addAll([
        (blockIndex >> 24) & 0xff,
        (blockIndex >> 16) & 0xff,
        (blockIndex >> 8) & 0xff,
        blockIndex & 0xff
      ]);
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

  // Helper: send a JSON payload string to all sockets listening on a game
  void sendToGameSockets(int gid, String payload) {
    final sockets = _gameSockets[gid];
    if (sockets != null) {
      for (final s in sockets) {
        try {
          s.sink.add(payload);
        } catch (_) {}
      }
    }
  }

  // Helper: build and broadcast the canonical game_state for a game
  Future<void> broadcastGameStateFor(int gid) async {
    try {
      final state = await fetchCanonicalGameState(gid);
      final statePayload = jsonEncode({
        'type': 'game_state',
        'game_id': gid,
        'players': state['players'],
        'totals': state['totals'],
        'ts': DateTime.now().toIso8601String()
      });
      sendToGameSockets(gid, statePayload);
    } catch (_) {}
  }

  router.get(
      '/health',
      (Request req) => Response.ok(jsonEncode({'ok': true}),
          headers: {'content-type': 'application/json'}));

  // Temporary debug endpoint
  router.get(
      '/ping',
      (Request req) =>
          Response.ok('pong', headers: {'content-type': 'text/plain'}));

  router.get('/games', (Request req) async {
    final res = await DB.conn.query(
        'SELECT g.id, g.course, g.date, g.holes, g.status, g.mode, g.created_by, u.name FROM games g LEFT JOIN users u ON g.created_by = u.id ORDER BY g.id DESC');
    final games = res.map((row) {
      return {
        'id': row[0],
        'course': row[1],
        'date': (row[2] as DateTime).toIso8601String(),
        'holes': row[3],
        'status': row[4],
        'mode': row[5],
        'created_by': row[6],
        'created_by_name': row[7],
      };
    }).toList();
    return Response.ok(jsonEncode(games),
        headers: {'content-type': 'application/json'});
  });

  router.get('/games/<id|[0-9]+>', (Request req, String id) async {
    final res = await DB.conn.query(
        'SELECT g.id, g.course, g.date, g.holes, g.status, g.created_by, u.name FROM games g LEFT JOIN users u ON g.created_by = u.id WHERE g.id = @id',
        substitutionValues: {'id': int.parse(id)});
    if (res.isEmpty) {
      return Response.notFound('Game not found');
    }
    final row = res.first;
    final game = {
      'id': row[0],
      'course': row[1],
      'date': (row[2] as DateTime).toIso8601String(),
      'holes': row[3],
      'status': row[4],
      'created_by': row[5],
      'created_by_name': row[6],
    };
    return Response.ok(jsonEncode(game),
        headers: {'content-type': 'application/json'});
  });

  router.post('/games', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final course = body['course'] as String? ?? 'Unknown';
    final date = body['date'] as String? ?? DateTime.now().toIso8601String();
    final holes = body['holes'] ?? 18;
    final mode = body['mode'] as String? ?? 'standard';
    final status = body['status'] as String? ?? 'pending';

    final requester = await userFromRequest(req);
    final createdBy = requester != null ? requester['id'] as int : null;

    // include created_by if we have an authenticated requester
    late List res;
    if (createdBy != null) {
      res = await DB.conn.query(
        'INSERT INTO games (course, date, holes, status, mode, created_by) VALUES (@course, @date, @holes, @status, @mode, @created_by) RETURNING id',
        substitutionValues: {
          'course': course,
          'date': DateTime.parse(date),
          'holes': holes,
          'status': status,
          'mode': mode,
          'created_by': createdBy
        },
      );
    } else {
      res = await DB.conn.query(
        'INSERT INTO games (course, date, holes, status, mode) VALUES (@course, @date, @holes, @status, @mode) RETURNING id',
        substitutionValues: {
          'course': course,
          'date': DateTime.parse(date),
          'holes': holes,
          'status': status,
          'mode': mode
        },
      );
    }
    final id = res.first[0] as int;

    // optional players list to pre-populate players for past games
    if (body.containsKey('players')) {
      final players = body['players'];
      if (players is List) {
        for (final p in players) {
          if (p is Map && p.containsKey('player_name')) {
            await DB.conn.query(
                'INSERT INTO game_players (game_id, player_name) VALUES (@gid, @pname)',
                substitutionValues: {'gid': id, 'pname': p['player_name']});
            // optionally accept per-hole strokes map
            if (p.containsKey('strokes') && p['strokes'] is Map) {
              final strokesMap = p['strokes'] as Map;
              for (final entry in strokesMap.entries) {
                final hole = int.tryParse(entry.key.toString()) ?? 0;
                final strokes = (entry.value as num).toInt();
                if (hole > 0) {
                  await DB.conn.query(
                      'INSERT INTO strokes (game_id, player_name, hole_number, strokes) VALUES (@gid, @pname, @hole, @strokes)',
                      substitutionValues: {
                        'gid': id,
                        'pname': p['player_name'],
                        'hole': hole,
                        'strokes': strokes
                      });
                }
              }
            }
          } else if (p is String) {
            await DB.conn.query(
                'INSERT INTO game_players (game_id, player_name) VALUES (@gid, @pname)',
                substitutionValues: {'gid': id, 'pname': p});
          }
        }
      }
    }

    // Ensure the creator is added as a player for the game (if authenticated)
    if (createdBy != null) {
      final creatorName = requester!['name'] as String? ?? '';
      if (creatorName.isNotEmpty) {
        final exists = await DB.conn.query(
            'SELECT count(*) FROM game_players WHERE game_id = @gid AND player_name = @p',
            substitutionValues: {'gid': id, 'p': creatorName});
        final cnt = (exists.first[0] as int?) ?? 0;
        if (cnt == 0) {
          await DB.conn.query(
              'INSERT INTO game_players (game_id, player_name, player_id) VALUES (@gid, @p, @pid)',
              substitutionValues: {
                'gid': id,
                'p': creatorName,
                'pid': createdBy
              });
        }
      }
    }

    return Response(201,
        body: jsonEncode({'id': id}),
        headers: {'content-type': 'application/json'});
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
    await DB.conn.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT");
    await DB.conn.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'viewer'");

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
      substitutionValues: {
        'name': name,
        'api': apiKey,
        'ph': passHash,
        'role': role
      },
    );
    final id = res.first[0] as int;
    return Response(201,
        body: jsonEncode({'id': id, 'api_key': apiKey, 'role': role}),
        headers: {'content-type': 'application/json'});
  });

  // Login: returns api_key and user info
  router.post('/login', (Request req) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final name = (body['name'] as String?)?.trim();
    final password = body['password'] as String?;
    if (name == null || password == null) {
      return Response(400, body: 'Missing name/password');
    }
    // ensure column exists
    await DB.conn.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS password_hash TEXT");
    await DB.conn.execute(
        "ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT DEFAULT 'viewer'");

    final res = await DB.conn.query(
        'SELECT id, name, api_key, password_hash, role FROM users WHERE name = @name',
        substitutionValues: {'name': name});
    if (res.isEmpty) {
      return Response.forbidden('Invalid credentials');
    }
    final row = res.first;
    final storedHash = row[3] as String?;
    if (storedHash == null || storedHash.isEmpty) {
      return Response(400, body: 'User has no password set');
    }
    final ok = verifyPassword(password, storedHash);
    if (!ok) {
      return Response.forbidden('Invalid credentials');
    }
    final user = {
      'id': row[0],
      'name': row[1],
      'api_key': row[2],
      'role': row[4]
    };
    return Response.ok(jsonEncode({'api_key': row[2], 'user': user}),
        headers: {'content-type': 'application/json'});
  });

  // Admin: list users
  router.get('/users', (Request req) async {
    final user = await userFromRequest(req);
    if (user == null || user['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    final res = await DB.conn
        .query('SELECT id, name, role, api_key FROM users ORDER BY id');
    final list = res
        .map((r) => {'id': r[0], 'name': r[1], 'role': r[2], 'api_key': r[3]})
        .toList();
    return Response.ok(jsonEncode(list),
        headers: {'content-type': 'application/json'});
  });

  // Admin: create user (alternate endpoint to register; requires admin)
  router.post('/users', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final name = (body['name'] as String?)?.trim();
    final password = body['password'] as String?;
    final role = (body['role'] as String?) ?? 'viewer';
    if (name == null || name.isEmpty || password == null || password.isEmpty) {
      return Response(400, body: 'Missing name or password');
    }
    final apiKey = randomToken();
    final passHash = makePasswordHash(password);
    final res = await DB.conn.query(
        'INSERT INTO users (name, api_key, password_hash, role) VALUES (@name, @api, @ph, @role) RETURNING id',
        substitutionValues: {
          'name': name,
          'api': apiKey,
          'ph': passHash,
          'role': role
        });
    final id = res.first[0] as int;
    return Response(201,
        body: jsonEncode({'id': id, 'api_key': apiKey, 'role': role}),
        headers: {'content-type': 'application/json'});
  });

  // Admin: update user role
  router.patch('/users/<id|[0-9]+>', (Request req, String id) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final updates = <String>[];
    final values = <String, dynamic>{'id': int.parse(id)};
    if (body.containsKey('role')) {
      updates.add('role = @role');
      values['role'] = body['role'];
    }
    if (updates.isEmpty) {
      return Response(400, body: 'Nothing to update');
    }
    final sql = 'UPDATE users SET ${updates.join(', ')} WHERE id = @id';
    await DB.conn.query(sql, substitutionValues: values);
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  });

  // Admin: revoke/regenerate api key for a user
  router.post('/users/<id|[0-9]+>/revoke', (Request req, String id) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    final newKey = randomToken();
    await DB.conn.query('UPDATE users SET api_key = @k WHERE id = @id',
        substitutionValues: {'k': newKey, 'id': int.parse(id)});
    return Response.ok(jsonEncode({'api_key': newKey}),
        headers: {'content-type': 'application/json'});
  });

  // Admin: delete a user
  router.delete('/users/<id|[0-9]+>', (Request req, String id) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    final uid = int.parse(id);
    // Ensure user exists
    final res = await DB.conn.query(
        'SELECT id, name, role FROM users WHERE id = @id',
        substitutionValues: {'id': uid});
    if (res.isEmpty) {
      return Response.notFound('User not found');
    }
    final targetRole = res.first[2] as String? ?? 'viewer';
    // Prevent deleting the last admin
    if (targetRole == 'admin') {
      final adminsRes = await DB.conn
          .query("SELECT count(*) FROM users WHERE role = 'admin'");
      final adminCount = (adminsRes.first[0] as int?) ?? 0;
      if (adminCount <= 1) {
        return Response(400, body: 'Cannot delete the last admin');
      }
    }
    await DB.conn.query('DELETE FROM users WHERE id = @id',
        substitutionValues: {'id': uid});
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  });

  // Change password for a user. Admins may change any user's password without current password.
  // Non-admin users must provide current_password.
  router.post('/users/<id|[0-9]+>/password', (Request req, String id) async {
    final requester = await userFromRequest(req);
    if (requester == null) {
      return Response.forbidden('Authentication required');
    }
    final uid = int.parse(id);
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final newPassword = body['new_password'] as String?;
    final currentPassword = body['current_password'] as String?;
    if (newPassword == null || newPassword.isEmpty) {
      return Response(400, body: 'Missing new_password');
    }

    // Permission: admin or same user
    final isAdmin = (requester['role'] as String?) == 'admin';
    if (!isAdmin && (requester['id'] as int) != uid) {
      return Response.forbidden('Cannot change other user password');
    }

    // Ensure target exists and, if non-admin, verify current password
    final res = await DB.conn.query(
        'SELECT password_hash FROM users WHERE id = @id',
        substitutionValues: {'id': uid});
    if (res.isEmpty) {
      return Response.notFound('User not found');
    }
    final storedHash = res.first[0] as String?;
    if (!isAdmin) {
      if (storedHash == null || storedHash.isEmpty) {
        return Response(400, body: 'User has no password set');
      }
      if (currentPassword == null ||
          !verifyPassword(currentPassword, storedHash)) {
        return Response.forbidden('Invalid current password');
      }
    }

    final passHash = makePasswordHash(newPassword);
    // rotate api key on password change to force re-login
    final newKey = randomToken();
    await DB.conn.query(
        'UPDATE users SET password_hash = @ph, api_key = @k WHERE id = @id',
        substitutionValues: {'ph': passHash, 'k': newKey, 'id': uid});
    return Response.ok(jsonEncode({'ok': true, 'api_key': newKey}),
        headers: {'content-type': 'application/json'});
  });

  router.patch('/games/<id|[0-9]+>', (Request req, String id) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final updates = <String>[];
    final values = <String, dynamic>{'id': int.parse(id)};
    if (body.containsKey('status')) {
      updates.add('status = @status');
      values['status'] = body['status'];
    }
    if (updates.isEmpty) {
      return Response(400, body: 'Nothing to update');
    }
    final sql = 'UPDATE games SET ${updates.join(', ')} WHERE id = @id';
    await DB.conn.query(sql, substitutionValues: values);
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  });

  router.post('/games/<id|[0-9]+>/strokes', (Request req, String id) async {
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final playerName = body['player_name'] as String? ?? 'Player';
    final holeNumber = body['hole_number'] as int? ?? 1;
    final providedRoundId = body.containsKey('round_id')
        ? (body['round_id'] is int
            ? body['round_id'] as int
            : int.tryParse(body['round_id'].toString()))
        : null;
    final strokes = body['strokes'] as int? ?? 1;
    final overwrite = body['overwrite'] as bool? ?? false;
    final gid = int.parse(id);
    // Determine or create round association. If client provided a round_id, validate it.
    int? roundId = providedRoundId;
    try {
      if (roundId != null) {
        final rr = await DB.conn.query(
            'SELECT id FROM rounds WHERE id = @rid AND game_id = @gid',
            substitutionValues: {'rid': roundId, 'gid': gid});
        if (rr.isEmpty) {
          return Response(400, body: 'Invalid round_id for this game');
        }
      } else {
        // find open round for this game (not finished)
        final or = await DB.conn.query(
            'SELECT id FROM rounds WHERE game_id = @gid AND finished_at IS NULL ORDER BY round_number DESC LIMIT 1',
            substitutionValues: {'gid': gid});
        if (or.isNotEmpty) {
          roundId = or.first[0] as int;
        } else {
          // no open round: create a new one automatically (round_number = max+1)
          final rn = await DB.conn.query(
              'SELECT COALESCE(MAX(round_number),0) + 1 FROM rounds WHERE game_id = @gid',
              substitutionValues: {'gid': gid});
          final roundNumber = rn.first[0] as int;
          final creatorRes = await DB.conn.query(
              'SELECT created_by FROM games WHERE id = @gid',
              substitutionValues: {'gid': gid});
          final createdBy =
              (creatorRes.isNotEmpty ? creatorRes.first[0] as int? : null);
          final ins = await DB.conn.query(
              'INSERT INTO rounds (game_id, round_number, created_by) VALUES (@gid, @rnum, @cb) RETURNING id',
              substitutionValues: {
                'gid': gid,
                'rnum': roundNumber,
                'cb': createdBy
              });
          roundId = ins.first[0] as int;
          // notify websockets about new round
          final rpayload = jsonEncode({
            'type': 'round_created',
            'game_id': gid,
            'round_id': roundId,
            'round_number': roundNumber,
            'ts': DateTime.now().toIso8601String()
          });
          sendToGameSockets(gid, rpayload);
        }
      }
    } catch (e) {
      return Response(500, body: 'Error determining round: $e');
    }

    // If this stroke is attached to a round, for pitch rounds enforce hole numbers 1..3
    try {
      // ignore: unnecessary_null_comparison
      if (roundId != null) {
        // for rounds we expect the pitch format (holes 1..3)
        if (holeNumber < 1 || holeNumber > 3) {
          return Response(400,
              body: 'Invalid hole number for pitch round, must be 1..3');
        }
      } else {
        // fallback: Validate hole number against the game's configured holes when present.
        final gr = await DB.conn.query('SELECT holes FROM games WHERE id = @id',
            substitutionValues: {'id': gid});
        int? gameHoles;
        if (gr.isNotEmpty) gameHoles = gr.first[0] as int?;
        final maxHoles = (gameHoles != null && gameHoles > 0) ? gameHoles : 99;
        if (holeNumber < 1 || holeNumber > maxHoles) {
          return Response(400,
              body: 'Invalid hole number, must be between 1 and $maxHoles');
        }
      }
    } catch (_) {}
    final user = await userFromRequest(req);
    if (user == null) {
      return Response.forbidden('Authentication required');
    }
    final role = (user['role'] as String?) ?? 'viewer';
    // viewers cannot post strokes
    if (role == 'viewer') {
      return Response.forbidden('Insufficient permissions');
    }
    // players: allow posting strokes only if the posting user is a participant
    // in this game, and the target player is also part of the same game.
    if (role == 'player') {
      final posterName = user['name'] as String;
      // check poster is participant in this game
      final posterRes = await DB.conn.query(
          'SELECT count(*) FROM game_players WHERE game_id = @gid AND player_name = @p',
          substitutionValues: {'gid': gid, 'p': posterName});
      final posterCount = (posterRes.first[0] as int?) ?? 0;
      if (posterCount == 0) {
        return Response.forbidden(
            'Players must be participants of the game to post strokes');
      }
      // check target exists in game
      final targetRes = await DB.conn.query(
          'SELECT count(*) FROM game_players WHERE game_id = @gid AND player_name = @p',
          substitutionValues: {'gid': gid, 'p': playerName});
      final targetCount = (targetRes.first[0] as int?) ?? 0;
      if (targetCount == 0) {
        return Response.forbidden('Target player not in game');
      }
    }
    if (overwrite) {
      await DB.conn.transaction((ctx) async {
        await ctx.query(
            'DELETE FROM strokes WHERE game_id = @gid AND player_name = @player AND hole_number = @hole AND (round_id IS NULL OR round_id = @rid)',
            substitutionValues: {
              'gid': gid,
              'player': playerName,
              'hole': holeNumber,
              'rid': roundId
            });
        await ctx.query(
            'INSERT INTO strokes (game_id, player_name, hole_number, strokes, round_id) VALUES (@gameId, @player, @hole, @strokes, @rid)',
            substitutionValues: {
              'gameId': gid,
              'player': playerName,
              'hole': holeNumber,
              'strokes': strokes,
              'rid': roundId
            });
      });
    } else {
      await DB.conn.query(
          'INSERT INTO strokes (game_id, player_name, hole_number, strokes, round_id) VALUES (@gameId, @player, @hole, @strokes, @rid)',
          substitutionValues: {
            'gameId': gid,
            'player': playerName,
            'hole': holeNumber,
            'strokes': strokes,
            'rid': roundId
          });
    }

    // Broadcast to websockets listeners of this game
    final payload = jsonEncode({
      'type': 'stroke',
      'game_id': gid,
      'player_name': playerName,
      'hole_number': holeNumber,
      'strokes': strokes,
      'round_id': roundId,
      'ts': DateTime.now().toIso8601String(),
      'overwrite': overwrite,
    });
    sendToGameSockets(gid, payload);
    await broadcastGameStateFor(gid);

    return Response(201,
        body: jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  });

  // Create a new round for a game (Pitch & Putt round of 3 holes)
  router.post('/games/<id|[0-9]+>/rounds', (Request req, String id) async {
    final user = await userFromRequest(req);
    if (user == null) {
      return Response.forbidden('Authentication required');
    }
    final gid = int.parse(id);
    try {
      final rn = await DB.conn.query(
          'SELECT COALESCE(MAX(round_number),0) + 1 FROM rounds WHERE game_id = @gid',
          substitutionValues: {'gid': gid});
      final roundNumber = rn.first[0] as int;
      final createdBy = user['id'] as int?;
      final ins = await DB.conn.query(
          'INSERT INTO rounds (game_id, round_number, created_by) VALUES (@gid, @rnum, @cb) RETURNING id',
          substitutionValues: {
            'gid': gid,
            'rnum': roundNumber,
            'cb': createdBy
          });
      final roundId = ins.first[0] as int;
      final payload = jsonEncode({
        'type': 'round_created',
        'game_id': gid,
        'round_id': roundId,
        'round_number': roundNumber,
        'ts': DateTime.now().toIso8601String()
      });
      sendToGameSockets(gid, payload);
      return Response(201,
          body: jsonEncode({'id': roundId, 'round_number': roundNumber}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response(500, body: 'Error creating round: $e');
    }
  });

  // List rounds for a game
  router.get('/games/<id|[0-9]+>/rounds', (Request req, String id) async {
    final gid = int.parse(id);
    try {
      final res = await DB.conn.query(
          'SELECT id, round_number, created_by, finished_at FROM rounds WHERE game_id = @gid ORDER BY round_number',
          substitutionValues: {'gid': gid});
      final rounds = res
          .map((r) => {
                'id': r[0],
                'round_number': r[1],
                'created_by': r[2],
                'finished_at':
                    r[3] != null ? (r[3] as DateTime).toIso8601String() : null,
              })
          .toList();
      return Response.ok(jsonEncode(rounds),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response(500, body: 'Error listing rounds: $e');
    }
  });

  // Get details for a specific round (per-player per-hole breakdown + totals)
  router.get('/games/<id|[0-9]+>/rounds/<rid|[0-9]+>',
      (Request req, String id, String rid) async {
    final gid = int.parse(id);
    final roundId = int.parse(rid);
    try {
      // verify round belongs to game
      final rr = await DB.conn.query(
          'SELECT id FROM rounds WHERE id = @rid AND game_id = @gid',
          substitutionValues: {'rid': roundId, 'gid': gid});
      if (rr.isEmpty) {
        return Response.notFound('Round not found');
      }
      final details = await fetchRoundDetails(roundId);
      return Response.ok(
          jsonEncode({
            'id': roundId,
            'game_id': gid,
            'players': details['players'],
            'totals': details['totals']
          }),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response(500, body: 'Error fetching round: $e');
    }
  });

  // Complete a round (set finished_at) and return round totals
  router.patch('/games/<id|[0-9]+>/rounds/<rid|[0-9]+>/complete',
      (Request req, String id, String rid) async {
    final user = await userFromRequest(req);
    if (user == null) {
      return Response.forbidden('Authentication required');
    }
    final gid = int.parse(id);
    final roundId = int.parse(rid);
    try {
      // Only game creator may finalize (as requested)
      final gr = await DB.conn.query(
          'SELECT created_by FROM games WHERE id = @gid',
          substitutionValues: {'gid': gid});
      final createdBy = gr.isNotEmpty ? gr.first[0] as int? : null;
      if (createdBy == null || createdBy != (user['id'] as int?)) {
        return Response.forbidden('Only game creator may complete rounds');
      }
      await DB.conn.query(
          'UPDATE rounds SET finished_at = now() WHERE id = @rid AND game_id = @gid',
          substitutionValues: {'rid': roundId, 'gid': gid});
      // compute totals for this round
      final Map<String, int> totals = await fetchRoundTotals(roundId);
      final payload = jsonEncode({
        'type': 'round_completed',
        'game_id': gid,
        'round_id': roundId,
        'totals': totals,
        'ts': DateTime.now().toIso8601String()
      });
      sendToGameSockets(gid, payload);
      await broadcastGameStateFor(gid);
      return Response.ok(jsonEncode({'ok': true, 'totals': totals}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response(500, body: 'Error completing round: $e');
    }
  });

  // Finalize a game: only creator may finalize. Returns stats and winner (lowest strokes total)
  router.post('/games/<id|[0-9]+>/finalize', (Request req, String id) async {
    final user = await userFromRequest(req);
    if (user == null) {
      return Response.forbidden('Authentication required');
    }
    final gid = int.parse(id);
    try {
      final gr = await DB.conn.query(
          'SELECT created_by FROM games WHERE id = @gid',
          substitutionValues: {'gid': gid});
      final createdBy = gr.isNotEmpty ? gr.first[0] as int? : null;
      if (createdBy == null || createdBy != (user['id'] as int?)) {
        return Response.forbidden('Only game creator may finalize the game');
      }
      // compute totals across all rounds/strokes
      final Map<String, int> totals = await fetchGameTotals(gid);
      if (totals.isEmpty) {
        return Response.ok(
            jsonEncode({'ok': true, 'message': 'No strokes recorded'}),
            headers: {'content-type': 'application/json'});
      }
      // determine winner by lowest total
      String? winner;
      int? best;
      totals.forEach((k, v) {
        if (best == null || v < best!) {
          best = v;
          winner = k;
        }
      });
      // mark game as finished
      try {
        await DB.conn.query(
            "UPDATE games SET status='finished' WHERE id = @gid",
            substitutionValues: {'gid': gid});
      } catch (_) {}
      final payload = jsonEncode({
        'type': 'game_finalized',
        'game_id': gid,
        'winner': winner,
        'totals': totals,
        'ts': DateTime.now().toIso8601String()
      });
      sendToGameSockets(gid, payload);
      return Response.ok(
          jsonEncode({'ok': true, 'winner': winner, 'totals': totals}),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response(500, body: 'Error finalizing game: $e');
    }
  });

  // Add a player to an existing game (invite/accept)
  router.post('/games/<id|[0-9]+>/players', (Request req, String id) async {
    final user = await userFromRequest(req);
    if (user == null) {
      return Response.forbidden('Authentication required');
    }
    final role = (user['role'] as String?) ?? 'viewer';
    if (role == 'viewer') {
      return Response.forbidden('Insufficient permissions');
    }
    final gid = int.parse(id);
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final playerName = (body['player_name'] as String?)?.trim();
    if (playerName == null || playerName.isEmpty) {
      return Response(400, body: 'Missing player_name');
    }

    // avoid duplicate
    final exists = await DB.conn.query(
        'SELECT count(*) FROM game_players WHERE game_id = @gid AND player_name = @p',
        substitutionValues: {'gid': gid, 'p': playerName});
    final cnt = (exists.first[0] as int?) ?? 0;
    if (cnt == 0) {
      await DB.conn.query(
          'INSERT INTO game_players (game_id, player_name) VALUES (@gid, @p)',
          substitutionValues: {'gid': gid, 'p': playerName});
      // notify websockets
      final payload = jsonEncode({
        'type': 'player_joined',
        'game_id': gid,
        'player_name': playerName,
        'ts': DateTime.now().toIso8601String()
      });
      sendToGameSockets(gid, payload);
    }
    // Also broadcast a canonical `game_state` to ensure all clients are in sync
    await broadcastGameStateFor(gid);
    return Response(201,
        body: jsonEncode({'ok': true, 'player_name': playerName}),
        headers: {'content-type': 'application/json'});
  });

  // Delete game and its strokes
  router.delete('/games/<id|[0-9]+>', (Request req, String id) async {
    final user = await userFromRequest(req);
    if (user == null) {
      return Response.forbidden('Authentication required');
    }
    final role = (user['role'] as String?) ?? 'viewer';
    if (role != 'admin' && role != 'editor') {
      return Response.forbidden('Requires admin/editor');
    }
    final gid = int.parse(id);
    await DB.conn.transaction((ctx) async {
      await ctx.query('DELETE FROM strokes WHERE game_id = @gid',
          substitutionValues: {'gid': gid});
      await ctx.query('DELETE FROM games WHERE id = @gid',
          substitutionValues: {'gid': gid});
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
    return Response.ok(jsonEncode({'ok': true}),
        headers: {'content-type': 'application/json'});
  });

  // WebSocket endpoint for live updates per game
  router.get('/ws/games/<id|[0-9]+>', webSocketHandler((webSocket, req) {
    // Log connection attempt (helpful for debugging client path issues)
    try {
      final logFile = File('ws_connections.log');
      final info = req?.requestedUri?.toString() ?? 'null-requestUri';
      logFile.writeAsStringSync(
          '${DateTime.now().toIso8601String()} CONNECT $info\n',
          mode: FileMode.append);
    } catch (_) {}

    // Try to obtain id from route params first, then fall back to parsing the request path
    String? idStr;
    try {
      idStr = req?.params['id'];
    } catch (_) {
      idStr = null;
    }
    if (idStr == null && req != null) {
      try {
        final path = req.requestedUri.path; // e.g. /ws/games/123
        final m = RegExp(r'/ws/games/([0-9]+)').firstMatch(path);
        if (m != null) idStr = m.group(1);
      } catch (_) {
        idStr = null;
      }
    }

    if (idStr == null) {
      try {
        webSocket.sink
            .add(jsonEncode({'type': 'error', 'reason': 'missing game id'}));
      } catch (_) {}
      try {
        webSocket.sink.close();
      } catch (_) {}
      return;
    }

    final gid = int.parse(idStr);
    _gameSockets.putIfAbsent(gid, () => <WebSocketChannel>{}).add(webSocket);
    webSocket.stream.listen((message) {
      // For now, just ignore incoming messages or could be used for commands
    }, onDone: () {
      _gameSockets[gid]?.remove(webSocket);
    });
  }));

  // WebSocket endpoint for admin live update notifications
  router.get('/ws/admin/updates', webSocketHandler((webSocket, req) {
    try {
      _adminSockets.add(webSocket);
    } catch (_) {}
    webSocket.stream.listen((message) {
      // no incoming messages expected
    }, onDone: () {
      _adminSockets.remove(webSocket);
    });
  }));

  // (hot_reload endpoint removed temporarily)

  // Admin: return the backend update log (update.log) content
  router.get('/admin/update_log', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    try {
      final file = File('update.log');
      if (!file.existsSync()) {
        return Response.ok(
            jsonEncode({
              'lines': [],
              'last_update_status': lastUpdateStatus,
              'last_update_message': lastUpdateMessage,
              'enabled': autoUpdateEnabled
            }),
            headers: {'content-type': 'application/json'});
      }
      final content = await file.readAsString();
      final lines = content
          .split(RegExp(r'\r?\n'))
          .where((l) => l.trim().isNotEmpty)
          .toList();
      return Response.ok(
          jsonEncode({
            'lines': lines,
            'last_update_status': lastUpdateStatus,
            'last_update_message': lastUpdateMessage,
            'last_update_started': lastUpdateStarted?.toIso8601String(),
            'enabled': autoUpdateEnabled
          }),
          headers: {'content-type': 'application/json'});
    } catch (e) {
      return Response(500, body: 'Error reading log');
    }
  });

  // (Admin HTML UI removed; admin endpoints remain accessible via API)

  // Admin: get/set auto-update status
  router.get('/admin/auto_update', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    return Response.ok(jsonEncode({'enabled': autoUpdateEnabled}),
        headers: {'content-type': 'application/json'});
  });

  router.post('/admin/auto_update', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    final body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    final enabled = body['enabled'] as bool?;
    if (enabled == null) {
      return Response(400, body: 'Missing enabled flag');
    }
    saveAutoUpdate(enabled);
    return Response.ok(jsonEncode({'ok': true, 'enabled': autoUpdateEnabled}),
        headers: {'content-type': 'application/json'});
  });

  // Admin: force immediate update (git pull / pub get / restart)
  router.post('/admin/trigger_update', (Request req) async {
    final requester = await userFromRequest(req);
    if (requester == null || requester['role'] != 'admin') {
      return Response.forbidden('Requires admin');
    }
    // run update asynchronously; endpoint will return before exiting
    Future(() async {
      await performUpdate();
    });
    return Response.ok(jsonEncode({'ok': true, 'message': 'Update started'}),
        headers: {'content-type': 'application/json'});
  });

  // Admin debug: list raw strokes and aggregated view for a game (optional round)
  // (admin debug endpoint for strokes removed)

  // Return the forwarding wrapper which rewrites Host from proxy headers
  return _forwardingWrapper;
}
