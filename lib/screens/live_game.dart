import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../services/api.dart';

class LiveGameScreen extends StatefulWidget {
  final int gameId;
  final String course;
  final int holes;
  final List<String>? initialPlayers;
  const LiveGameScreen({
    super.key,
    required this.gameId,
    required this.course,
    this.holes = 18,
    this.initialPlayers,
  });

  @override
  State<LiveGameScreen> createState() => _LiveGameScreenState();
}

class _LiveGameScreenState extends State<LiveGameScreen> {
  WebSocketChannel? _channel;
  final List<String> _events = [];
  StreamSubscription? _sub;
  int _currentHole = 1;
  int _strokesToAdd = 1;
  String? _activePlayer;
  bool _pitchMode = false;
  int? _currentRoundId;
  // list of rounds (id, round_number, started_at, finished_at)
  final List<Map<String, dynamic>> _rounds = [];
  // cached details for the last finished round
  Map<String, Map<int, int>> _lastRoundPlayers = {};
  Map<String, int> _lastRoundTotals = {};
  int? _lastRoundIdLoaded;
  bool _loadingLastRound = false;
  // track the last finished round id explicitly to avoid races with newly-created rounds
  int? _lastFinishedRoundId;
  // Completer to await canonical game_state when deciding to prompt for next round
  Completer<Map<String, dynamic>>? _pendingGameStateCompleter;
  // Track recent local writes to avoid showing duplicates when the server echoes the stroke
  final Set<String> _recentLocalWrites = {};
  // player -> hole -> strokes
  final Map<String, Map<int, int>> _scores = {};

  @override
  void initState() {
    super.initState();
    // load cached scores if present (async)
    _initCacheAndWs();
  }

  List<int> _computeLastRoundHoles() {
    final holes = <int>{};
    _lastRoundPlayers.forEach((_, hm) {
      for (var h in hm.keys) {
        holes.add(h);
      }
    });
    final list = holes.toList()..sort();
    return list;
  }

  Future<void> _loadLastRoundDetails() async {
    if (_loadingLastRound) return;
    try {
      if (_rounds.isEmpty) return;
      // prefer explicit last finished round id if we have it
      int? rid = _lastFinishedRoundId;
      Map<String, dynamic>? last;
      if (rid == null) {
        // find last finished round
        for (var i = _rounds.length - 1; i >= 0; i--) {
          final candidate = _rounds[i];
          if (candidate['finished_at'] != null) {
            last = candidate;
            break;
          }
        }
        if (last == null && _rounds.isNotEmpty) last = _rounds.last;
        if (last == null) return;
        rid = last['id'] as int?;
      }
      if (rid == null) return;
      if (_lastRoundIdLoaded != null && _lastRoundIdLoaded == rid) return;
      setState(() {
        _loadingLastRound = true;
      });
      final resp = await Api.getRound(widget.gameId, rid);
      final playersRaw = (resp['players'] as Map?) ?? {};
      final Map<String, Map<int, int>> players = {};
      final Map<String, int> totals = {};
      playersRaw.forEach((k, v) {
        final pname = k.toString();
        final hm = <int, int>{};
        if (v is Map) {
          v.forEach((hk, hv) {
            final hn = int.tryParse(hk.toString()) ?? 0;
            if (hn > 0) {
              final val = (hv is num) ? hv.toInt() : (int.tryParse(hv.toString()) ?? 0);
              hm[hn] = val;
              totals[pname] = (totals[pname] ?? 0) + val;
            }
          });
        }
        players[pname] = hm;
      });
      if (!mounted) return;
      setState(() {
        _lastRoundPlayers = players;
        _lastRoundTotals = totals;
        _lastRoundIdLoaded = rid;
        // if this round is finished, record it explicitly
        _lastFinishedRoundId = rid;
      });
    } catch (e) {
      // ignore errors; we still ensure the loading flag is cleared below
    } finally {
      if (mounted) setState(() => _loadingLastRound = false);
    }
  }

  Future<void> _loadRoundDetails(int rid) async {
    if (_loadingLastRound) return;
    try {
      setState(() { _loadingLastRound = true; });
      final resp = await Api.getRound(widget.gameId, rid);
      final playersRaw = (resp['players'] as Map?) ?? {};
      final Map<String, Map<int, int>> players = {};
      final Map<String, int> totals = {};
      playersRaw.forEach((k, v) {
        final pname = k.toString();
        final hm = <int, int>{};
        if (v is Map) {
          v.forEach((hk, hv) {
            final hn = int.tryParse(hk.toString()) ?? 0;
            if (hn > 0) {
              final val = (hv is num) ? hv.toInt() : (int.tryParse(hv.toString()) ?? 0);
              hm[hn] = val;
              totals[pname] = (totals[pname] ?? 0) + val;
            }
          });
        }
        players[pname] = hm;
      });
      if (!mounted) return;
      setState(() {
        _lastRoundPlayers = players;
        _lastRoundTotals = totals;
        _lastRoundIdLoaded = rid;
        // if this round is finished, remember it
        final idx = _rounds.indexWhere((rr) => rr['id'] == rid);
        if (idx != -1 && _rounds[idx]['finished_at'] != null) {
          _lastFinishedRoundId = rid;
        }
      });
    } catch (e) {
      // ignore
    } finally {
      if (mounted) setState(() => _loadingLastRound = false);
    }
  }

  Future<void> _initCacheAndWs() async {
    try {
      if (!Hive.isBoxOpen('live_cache')) await Hive.openBox('live_cache');
      final box = Hive.box('live_cache');
      final key = 'game_${widget.gameId}';
      if (box.containsKey(key)) {
        final raw = box.get(key) as String?;
        if (raw != null) {
          final decoded = jsonDecode(raw) as Map<String, dynamic>;
          decoded.forEach((player, holesMap) {
            final hm = <int, int>{};
            if (holesMap is Map) {
              holesMap.forEach((k, v) {
                hm[int.parse(k.toString())] = (v as num).toInt();
              });
            }
            _scores[player] = hm;
          });
        }
      }
      // ensure initial players (e.g., creator) are present immediately
      if (widget.initialPlayers != null) {
        for (final p in widget.initialPlayers!) {
          _scores.putIfAbsent(p, () => <int, int>{});
          _activePlayer ??= p;
        }
      }
      // load cached rounds if present
      try {
        if (box.containsKey('${key}_rounds')) {
          final rawRounds = box.get('${key}_rounds') as String?;
          if (rawRounds != null) {
            final rr = jsonDecode(rawRounds) as List<dynamic>;
            _rounds.clear();
            _rounds.addAll(rr.map((e) => Map<String, dynamic>.from(e as Map)));
          }
        }
      } catch (_) {}
      // if no cached rounds, try to fetch from server
      if (_rounds.isEmpty) {
        try {
          final remote = await Api.getRounds(widget.gameId);
          if (remote.isNotEmpty) {
            _rounds.clear();
            _rounds.addAll(remote);
            try {
              final box = Hive.box('live_cache');
              box.put('game_${widget.gameId}_rounds', jsonEncode(_rounds));
            } catch (_) {}
          }
        } catch (_) {}
      }
      // load last round details from server if cached rounds exist
      try {
        await _loadLastRoundDetails();
      } catch (_) {}
      // fetch game metadata to initialize mode (e.g., Pitch & Putt)
      try {
        final games = await Api.getGames();
        final me = games.firstWhere(
          (g) => (g['id'] as int) == widget.gameId,
          orElse: () => <String, dynamic>{},
        );
        if (me.isNotEmpty) {
          final mode = (me['mode'] as String?) ?? 'standard';
          setState(() {
            _pitchMode = mode == 'pitch';
          });
          if (_pitchMode) {
            // create an initial round if none exists
            try {
              final res = await Api.createRound(widget.gameId);
              final rid = res['id'] as int? ?? (res['round_id'] as int?);
              setState(() {
                _currentRoundId = rid;
                _currentHole = 1;
              });
            } catch (_) {}
          }
        }
      } catch (_) {}
    } catch (_) {}
    // initialize _lastFinishedRoundId from cached rounds if we have one
    try {
      for (var i = _rounds.length - 1; i >= 0; i--) {
        final candidate = _rounds[i];
        if (candidate['finished_at'] != null) {
          _lastFinishedRoundId = candidate['id'] as int?;
          break;
        }
      }
    } catch (_) {}
    final channel = _channel = Api.wsForGame(widget.gameId);
    _sub = channel.stream.listen(
      (data) {
        try {
          final msg = data is String ? jsonDecode(data) : data;
          if (msg is Map && msg['type'] == 'stroke') {
            final player = msg['player_name'] as String? ?? 'Unknown';
            final hole = (msg['hole_number'] as num?)?.toInt() ?? 1;
            final strokes = (msg['strokes'] as num?)?.toInt() ?? 1;
            final round = msg['round_id'] is int
                ? msg['round_id'] as int
                : (msg['round_id'] != null
                      ? int.tryParse(msg['round_id'].toString())
                      : null);
            final dedupeKey = '$player|$hole|$strokes|${round ?? ''}';
            if (_recentLocalWrites.contains(dedupeKey)) {
              // already applied locally — ignore this echo and remove dedupe marker
              _recentLocalWrites.remove(dedupeKey);
              return;
            }
            setState(() {
              final p = _scores.putIfAbsent(player, () => <int, int>{});
              p[hole] = (p[hole] ?? 0) + strokes;
              final ts = msg['ts'] ?? '';
              _events.insert(0, '$ts $player: hole $hole -> $strokes');
            });
            if (round != null) {
              // Only refresh last-round details if this stroke belongs to the
              // last finished round we currently know about. Avoid re-loading
              // when the server announces a newly-created (empty) round which
              // would overwrite the finished round view.
              try {
                final lastFinished = _rounds.isNotEmpty
                    ? _rounds.lastWhere((r) => r['finished_at'] != null, orElse: () => <String, dynamic>{})
                    : <String, dynamic>{};
                final lastRid = lastFinished.isNotEmpty ? (lastFinished['id'] as int?) : null;
                if (lastRid != null && lastRid == round) {
                  _loadLastRoundDetails();
                }
              } catch (_) {}
            }
          } else if (msg is Map && msg['type'] == 'round_created') {
            try {
              final r = Map<String, dynamic>.from(msg['round'] as Map? ?? {});
              final exists = _rounds.any((rr) => rr['id'] == r['id']);
              if (!exists) {
                setState(() {
                  _rounds.add(r);
                  _currentRoundId = r['id'] as int? ?? _currentRoundId;
                  _events.insert(
                    0,
                    '${msg['ts'] ?? ''} round_created: ${r['id']}',
                  );
                });
                try {
                  final box = Hive.box('live_cache');
                  box.put('game_${widget.gameId}_rounds', jsonEncode(_rounds));
                } catch (_) {}
              }
            } catch (_) {}
          } else if (msg is Map && msg['type'] == 'round_completed') {
            try {
              final rid = msg['round_id'] is int
                  ? msg['round_id'] as int
                  : int.tryParse(msg['round_id'].toString());
              if (rid != null) {
                final idx = _rounds.indexWhere((rr) => rr['id'] == rid);
                if (idx != -1) {
                  setState(() {
                    _rounds[idx]['finished_at'] =
                        msg['finished_at'] ?? DateTime.now().toIso8601String();
                    _events.insert(
                      0,
                      '${msg['ts'] ?? ''} round_completed: $rid',
                    );
                  });
                  // mark last finished round explicitly and load it
                  _lastFinishedRoundId = rid;
                  _loadRoundDetails(rid);
                  try {
                    final box = Hive.box('live_cache');
                    box.put(
                      'game_${widget.gameId}_rounds',
                      jsonEncode(_rounds),
                    );
                  } catch (_) {}
                }
              }
            } catch (_) {}
          } else if (msg is Map && msg['type'] == 'game_state') {
            // Canonical state from server: replace local scores
            try {
              final players =
                  (msg['players'] as Map?)?.cast<String, dynamic>() ?? {};
              // If someone is awaiting canonical state for a prompt, complete it with the players map
              try {
                if (_pendingGameStateCompleter != null &&
                    !_pendingGameStateCompleter!.isCompleted) {
                  _pendingGameStateCompleter!.complete({
                    'players': players,
                    'ts': msg['ts'],
                  });
                }
              } catch (_) {}
              setState(() {
                _scores.clear();
                players.forEach((player, holesMap) {
                  final Map<int, int> hm = {};
                  if (holesMap is Map) {
                    holesMap.forEach((k, v) {
                      hm[int.parse(k.toString())] = (v as num).toInt();
                    });
                  }
                  _scores[player] = hm;
                });
                _events.insert(0, '${msg['ts'] ?? ''} game_state sync');
              });
              _saveCache();
            } catch (e) {
              setState(() => _events.insert(0, 'game_state parse error: $e'));
            }
          } else if (msg is Map && msg['type'] == 'player_joined') {
            final pname = msg['player_name'] as String? ?? '';
            setState(() {
              _scores.putIfAbsent(pname, () => <int, int>{});
              _events.insert(0, '${msg['ts'] ?? ''} player_joined: $pname');
            });
          } else {
            setState(() => _events.insert(0, data.toString()));
          }
        } catch (e) {
          setState(() => _events.insert(0, 'WS parse error: $e'));
        }
      },
      onError: (e) {
        setState(() => _events.insert(0, 'WS error: $e'));
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  Future<void> _addStroke() async {
    // For demo: add a fixed stroke event
    try {
      final player = _activePlayer ?? 'Jogador';
      if (player.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selecione um jogador para marcar')),
        );
        return;
      }
      // Ensure we have a round id associated; create one if missing
      if (_currentRoundId == null) {
        try {
          final res = await Api.createRound(widget.gameId);
          final rid = res['id'] as int? ?? (res['round_id'] as int?);
          if (rid != null) {
            setState(() {
              _currentRoundId = rid;
            });
            try {
              _rounds.add({
                'id': rid,
                'round_number': (_rounds.length + 1),
                'started_at': DateTime.now().toIso8601String(),
              });
              final box = Hive.box('live_cache');
              box.put('game_${widget.gameId}_rounds', jsonEncode(_rounds));
            } catch (_) {}
          }
        } catch (_) {}
      }

      await Api.addStroke(
        widget.gameId,
        player,
        _currentHole,
        _strokesToAdd,
        roundId: _currentRoundId,
      );
      if (!mounted) return;
      // Update UI immediately as a fallback in case the server's websocket
      // broadcast is delayed or not received. The canonical `game_state`
      // from the server will later replace this if needed.
      setState(() {
        final p = _scores.putIfAbsent(player, () => <int, int>{});
        p[_currentHole] = (p[_currentHole] ?? 0) + _strokesToAdd;
        _events.insert(
          0,
          'Enviado: $player: hole $_currentHole -> $_strokesToAdd',
        );
      });
      _saveCache();
      // Do not reload last-round details here — the WebSocket and
      // round_completed events will update the last-round view when
      // appropriate. Reloading here can accidentally load a newly-created
      // empty round and hide the finished round's table.
      // add dedupe key so when server echoes the stroke we don't double-apply
      final dedupeKey =
          '$player|$_currentHole|$_strokesToAdd|${_currentRoundId ?? ''}';
      _recentLocalWrites.add(dedupeKey);
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(const SnackBar(content: Text('Stroke enviado')));
      // auto-advance hole and initialize zeros; respect game's holes when set, otherwise allow up to 99
      final maxAllowedHole = _pitchMode
          ? 3
          : (widget.holes > 0 ? widget.holes : 99);
      final oldHole = _currentHole;
      final shouldAdvance = _currentHole < maxAllowedHole;
      if (shouldAdvance) {
        final newHole = _currentHole + 1;
        setState(() {
          _currentHole = newHole;
          _strokesToAdd = 1;
          for (final p in _scores.keys) {
            _scores[p] = _scores[p] ?? <int, int>{};
            if (newHole <= maxAllowedHole) {
              _scores[p]![newHole] = _scores[p]![newHole] ?? 0;
            }
          }
        });
      }

      // If in pitch mode and we just completed hole 3 (oldHole == 3), ask to continue or end round
      if (_pitchMode && oldHole == 3) {
        // only prompt when ALL players have a non-zero entry for hole 3
        final players = _scores.keys.toList();
        final allHave3 =
            players.isNotEmpty &&
            players.every((p) => (_scores[p]?[3] ?? 0) > 0);
        if (allHave3) {
          // Wait for canonical game_state from server to avoid prompting prematurely.
          _pendingGameStateCompleter = Completer<Map<String, dynamic>>();
          Map<String, dynamic>? canonical;
          try {
            // wait up to 3 seconds for server canonical state, otherwise fall back to local
            canonical = await _pendingGameStateCompleter!.future.timeout(
              const Duration(seconds: 3),
            );
          } catch (_) {
            canonical = null;
            if (!mounted) return;
          } finally {
            _pendingGameStateCompleter = null;
          }

          bool shouldPrompt = false;
          if (canonical != null && canonical['players'] is Map) {
            final cp = (canonical['players'] as Map).cast<String, dynamic>();
            final playersList = cp.keys.toList();
            if (playersList.isNotEmpty) {
              final allHave3Canonical = playersList.every((p) {
                final holesMap = cp[p] as Map?;
                final v = holesMap != null
                    ? (holesMap['3'] ?? holesMap[3])
                    : null;
                final intVal = v is num
                    ? v.toInt()
                    : (v is String ? int.tryParse(v) ?? 0 : 0);
                return intVal > 0;
              });
              shouldPrompt = allHave3Canonical;
            }
          } else {
            shouldPrompt = allHave3; // fallback to local state
          }

          if (shouldPrompt) {
            final playMore = await showDialog<bool>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Round terminado'),
                content: const Text('Queres jogar mais um round?'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Não, acabar'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Sim, próximo'),
                  ),
                ],
              ),
            );

            if (playMore == true) {
              try {
                // load details for the just-played round so the UI shows its table
                try {
                  if (_currentRoundId != null) {
                    await _loadRoundDetails(_currentRoundId!);
                  }
                } catch (_) {}
                final res = await Api.createRound(widget.gameId);
                final rid = res['id'] as int? ?? (res['round_id'] as int?);
                if (!mounted) return;
                setState(() {
                  _currentRoundId = rid;
                  _currentHole = 1;
                  // Reset per-player scores for the new round (Pitch & Putt uses 3 holes)
                  if (_pitchMode) {
                    for (final p in _scores.keys) {
                      _scores[p] = <int, int>{1: 0, 2: 0, 3: 0};
                    }
                  }
                });
                _saveCache();
                // record the created round locally
                try {
                  final r = <String, dynamic>{
                    'id': rid,
                    'round_number': (_rounds.length + 1),
                    'started_at': DateTime.now().toIso8601String(),
                  };
                  _rounds.add(r);
                  final box = Hive.box('live_cache');
                  box.put('game_${widget.gameId}_rounds', jsonEncode(_rounds));
                } catch (_) {}
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Erro a criar round: $e')),
                );
                if (!mounted) return;
              }
            } else {
              try {
                if (_currentRoundId != null) {
                  await Api.completeRound(widget.gameId, _currentRoundId!);
                }
                final stats = await Api.finalizeGame(widget.gameId);
                if (!mounted) return;
                // mark current round finished locally
                try {
                  if (_currentRoundId != null) {
                    final idx = _rounds.indexWhere(
                      (rr) => rr['id'] == _currentRoundId,
                    );
                    if (idx != -1) {
                      _rounds[idx]['finished_at'] = DateTime.now()
                          .toIso8601String();
                      try {
                        final box = Hive.box('live_cache');
                        box.put(
                          'game_${widget.gameId}_rounds',
                          jsonEncode(_rounds),
                        );
                      } catch (_) {}
                    }
                  }
                } catch (_) {}
                await showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Jogo finalizado'),
                    content: SingleChildScrollView(
                      child: Text(
                        "Vencedor: ${stats['winner']}\nTotals: ${stats['totals']}",
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Erro a finalizar: $e')));
              }
            }
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erro: $e')));
    }
  }

  Future<void> _invitePlayer() async {
    try {
      List<Map<String, dynamic>> users = [];
      var allowManual = false;
      try {
        users = await Api.listUsers();
      } catch (_) {
        // listing users may be forbidden for non-admins or unavailable; fall back to manual entry
        allowManual = true;
      }
      final existing = _scores.keys.toSet();
      final current = Api.currentUser();
      final filtered = users.where((u) {
        final name = u['name'] as String? ?? '';
        if (name.isEmpty) return false;
        if (existing.contains(name)) return false;
        if (current != null && current['name'] == name) return false;
        return true;
      }).toList();
      String? sel;
      if (filtered.isNotEmpty && !allowManual) {
        if (!mounted) return;
        sel = await showDialog<String?>(
          context: context,
          builder: (_) => SimpleDialog(
            title: const Text('Convidar utilizador'),
            children: filtered.map((u) {
              final name = u['name'] as String? ?? '';
              return SimpleDialogOption(
                onPressed: () => Navigator.pop(context, name),
                child: Text(name),
              );
            }).toList(),
          ),
        );
      } else {
        // fallback: ask user to type a username to invite
        final ctrl = TextEditingController();
        if (!mounted) return;
        sel = await showDialog<String?>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Convidar utilizador (manual)'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Nome de utilizador',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, ctrl.text.trim()),
                child: const Text('Convidar'),
              ),
            ],
          ),
        );
      }
      if (sel == null) return;
      final pname = sel;
      final ok = await Api.addPlayer(widget.gameId, pname);
      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Erro ao convidar')));
        return;
      }
      setState(() {
        _scores.putIfAbsent(pname, () => <int, int>{});
        _activePlayer ??= pname;
      });
      _saveCache();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Convidado: $sel')));
    } catch (e) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text('Erro: $e')));
    }
  }

  void _saveCache() {
    try {
      final box = Hive.box('live_cache');
      final key = 'game_${widget.gameId}';
      final enc = <String, Map<String, int>>{};
      _scores.forEach((player, holes) {
        final map = <String, int>{};
        holes.forEach((k, v) => map[k.toString()] = v);
        enc[player] = map;
      });
      box.put(key, jsonEncode(enc));
    } catch (_) {}
  }

  Future<void> _editCell(String player, int hole) async {
    final current = _scores[player]?[hole] ?? 0;
    final ctrl = TextEditingController(text: current.toString());
    final res = await showDialog<int?>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Editar tacadas — $player (buraco $hole)'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Tacadas'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () {
              final v = int.tryParse(ctrl.text) ?? current;
              Navigator.pop(context, v);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (res != null) {
      // persist overwrite to server
      try {
        await Api.addStroke(widget.gameId, player, hole, res, overwrite: true);
        setState(() {
          final p = _scores.putIfAbsent(player, () => <int, int>{});
          p[hole] = res;
          _events.insert(0, 'Editado: $player hole $hole -> $res');
        });
        _saveCache();
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          const SnackBar(content: Text('Tacadas atualizadas')),
        );
      } catch (e) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(
          SnackBar(content: Text('Erro ao actualizar: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final int maxAllowedHole = _pitchMode
        ? 3
        : (widget.holes > 0 ? widget.holes : 99);
    return Scaffold(
      appBar: AppBar(
        title: Text('Live — ${widget.course}'),
        actions: [],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 8.0,
            ),
            child: Row(
              children: [
                Text(
                  'Buraco: $_currentHole / ${widget.holes == 0 ? '?' : widget.holes}',
                ),
                const SizedBox(width: 12),
                if (_scores.isNotEmpty)
                  DropdownButton<String>(
                    value:
                        _activePlayer ??
                        (_scores.keys.isNotEmpty ? _scores.keys.first : null),
                    hint: const Text('Selecionar jogador'),
                    items: _scores.keys
                        .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                        .toList(),
                    onChanged: (v) => setState(() => _activePlayer = v),
                  ),
                const SizedBox(width: 12),
                IconButton(
                  icon: const Icon(Icons.remove),
                  onPressed: _currentHole > 1
                      ? () {
                          final newHole = _currentHole - 1;
                          setState(() {
                            _currentHole = newHole;
                            _strokesToAdd = 1;
                            // initialize zeros for this hole for existing players
                            for (final p in _scores.keys) {
                              _scores[p] = _scores[p] ?? <int, int>{};
                              _scores[p]![newHole] = _scores[p]![newHole] ?? 0;
                            }
                          });
                        }
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _currentHole < maxAllowedHole
                      ? () {
                          final newHole = _currentHole + 1;
                          setState(() {
                            _currentHole = newHole;
                            _strokesToAdd = 1;
                            for (final p in _scores.keys) {
                              _scores[p] = _scores[p] ?? <int, int>{};
                              if (newHole <= maxAllowedHole) {
                                _scores[p]![newHole] =
                                    _scores[p]![newHole] ?? 0;
                              }
                            }
                          });
                        }
                      : null,
                ),
                const SizedBox(width: 12),
                // Show game mode (Pitch & Putt games are initialized from game metadata)
                Padding(
                  padding: const EdgeInsets.only(right: 12.0),
                  child: Text(
                    'Modo: ${_pitchMode ? 'Pitch & Putt' : 'Standard'}',
                  ),
                ),
                const Spacer(),
                Text('Tacadas: $_strokesToAdd'),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _strokesToAdd > 1
                      ? () => setState(() => _strokesToAdd--)
                      : null,
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => setState(() => _strokesToAdd++),
                ),
              ],
            ),
          ),
          ElevatedButton(
            onPressed: _addStroke,
            child: const Text('Adicionar stroke'),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _invitePlayer,
            child: const Text('Convidar jogador'),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Jogo: ${widget.course}   Buraco atual: $_currentHole',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_rounds.isNotEmpty) ...[
                    const Text('Rounds:'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: _rounds.map((r) {
                        final rn = r['round_number'] ?? r['id'];
                        final finished = r['finished_at'] != null;
                        final color = finished ? Colors.grey : Colors.green;
                        final icon = finished ? Icons.check : Icons.play_arrow;
                        return ActionChip(
                          avatar: CircleAvatar(
                            backgroundColor: color,
                            child: Icon(icon, size: 16, color: Colors.white),
                          ),
                          label: Text('R$rn'),
                          onPressed: () async {
                            final rid = r['id'] as int?;
                            if (rid == null) {
                              await showDialog(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: Text('Round $rn'),
                                  content: const Text('Round sem id'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Fechar'),
                                    ),
                                  ],
                                ),
                              );
                              return;
                            }
                            try {
                              final resp = await Api.getRound(
                                widget.gameId,
                                rid,
                              );
                              final playersRaw =
                                  (resp['players'] as Map?) ?? {};
                              final Map<String, Map<int, int>> players = {};
                              final holesSet = <int>{};
                              playersRaw.forEach((k, v) {
                                final pname = k.toString();
                                final hm = <int, int>{};
                                if (v is Map) {
                                  v.forEach((hk, hv) {
                                    final hn = int.tryParse(hk.toString()) ?? 0;
                                    if (hn > 0) {
                                      final val = (hv is num)
                                          ? hv.toInt()
                                          : (int.tryParse(hv.toString()) ?? 0);
                                      hm[hn] = val;
                                      holesSet.add(hn);
                                    }
                                  });
                                }
                                players[pname] = hm;
                              });
                              final holes = holesSet.toList()..sort();
                              if (players.isEmpty) {
                                await showDialog(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: Text('Round $rn — Tabela'),
                                    content: const Text(
                                      'Nenhuma tacada registada neste round.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Fechar'),
                                      ),
                                    ],
                                  ),
                                );
                              } else {
                                await showDialog(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: Text('Round $rn — Tabela'),
                                    content: SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: DataTable(
                                        columns: [
                                          const DataColumn(
                                            label: Text('Player'),
                                          ),
                                          ...holes.map(
                                            (h) =>
                                                DataColumn(label: Text('$h')),
                                          ),
                                          const DataColumn(
                                            label: Text('Total'),
                                          ),
                                        ],
                                        rows: players.keys.map((pname) {
                                          final hm = players[pname] ?? {};
                                          int total = 0;
                                          final cells = <DataCell>[
                                            DataCell(Text(pname)),
                                          ];
                                          for (final h in holes) {
                                            final v = hm[h];
                                            if (v == null) {
                                              cells.add(
                                                const DataCell(Text('-')),
                                              );
                                            } else {
                                              total += v;
                                              cells.add(DataCell(Text('$v')));
                                            }
                                          }
                                          cells.add(DataCell(Text('$total')));
                                          return DataRow(cells: cells);
                                        }).toList(),
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Fechar'),
                                      ),
                                    ],
                                  ),
                                );
                              }
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Erro a obter round: $e'),
                                ),
                              );
                            }
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _buildScoreTable(),
                  const SizedBox(height: 12),
                  const Text('Último round (detalhes):'),
                  const SizedBox(height: 6),
                  _loadingLastRound
                      ? const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: CircularProgressIndicator(),
                        )
                      : _lastRoundPlayers.isEmpty
                          ? const Text('Nenhum round jogado ainda.')
                            : (() {
                                final holes = _computeLastRoundHoles();
                                String? winner;
                                if (_lastRoundTotals.isNotEmpty) {
                                  try {
                                    winner = _lastRoundTotals.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
                                  } catch (_) {
                                    winner = null;
                                  }
                                }
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: DataTable(
                                    columns: [
                                      const DataColumn(label: Text('Player')),
                                      // holes present
                                      ...holes.map((h) => DataColumn(label: Text('$h'))),
                                      const DataColumn(label: Text('Total')),
                                    ],
                                    rows: _lastRoundPlayers.keys.map((pname) {
                                      final hm = _lastRoundPlayers[pname] ?? {};
                                      int total = _lastRoundTotals[pname] ?? 0;
                                      final cells = <DataCell>[];
                                      // name cell with winner icon
                                      final isWinner = (winner != null && winner == pname);
                                      cells.add(
                                        DataCell(Row(
                                          children: [
                                            if (isWinner) ...[
                                              Icon(Icons.star, size: 16, color: Colors.green[800]),
                                              const SizedBox(width: 6),
                                            ],
                                            Text(pname),
                                          ],
                                        )),
                                      );
                                      for (final h in holes) {
                                        final v = hm[h];
                                        cells.add(DataCell(Text(v == null ? '-' : '$v')));
                                      }
                                      cells.add(DataCell(Text('$total')));
                                      return DataRow(
                                        color: isWinner ? MaterialStateProperty.all(Colors.greenAccent.withAlpha(70)) : null,
                                        cells: cells,
                                      );
                                    }).toList(),
                                  ),
                                );
                              })(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  

  Widget _buildScoreTable() {
    // Sort players by total score ascending (lower is better) so leader is on top
    final players = _scores.keys.toList();
    // compute totals; players with no strokes treated as 0
    final Map<String, int> totals = {};
    for (final p in players) {
      var t = 0;
      final hm = _scores[p];
      if (hm != null && hm.isNotEmpty) {
        for (final v in hm.values) {
          t += v;
        }
      }
      totals[p] = t;
    }
    players.sort((a, b) {
      final ta = totals[a] ?? 0;
      final tb = totals[b] ?? 0;
      if (ta != tb) return ta.compareTo(tb);
      return a.compareTo(b);
    });
    // Determine holes to display. If widget.holes == 0 we treat as dynamic and compute max from scores/current
    int maxHole = widget.holes > 0 ? widget.holes : _currentHole;
    for (final p in _scores.keys) {
      for (final h in _scores[p]!.keys) {
        if (h > maxHole) maxHole = h;
      }
    }
    final holes = List<int>.generate(maxHole, (i) => i + 1);

    // compute best per hole
    final Map<int, int> best = {};
    for (final h in holes) {
      int? b;
      for (final p in players) {
        final v = _scores[p]?[h];
        // treat 0 or null as not present (do not consider for best)
        if (v != null && v > 0) {
          if (b == null || v < b) b = v;
        }
      }
      if (b != null) best[h] = b;
    }

    DataColumn col(String label, {TextStyle? style}) =>
        DataColumn(label: Text(label, style: style));

    final headerStyle = TextStyle(fontWeight: FontWeight.bold);
    final columns = <DataColumn>[col('Player', style: headerStyle)];
    columns.addAll(
      holes.map(
        (h) => col(
          '$h',
          style: h == _currentHole
              ? headerStyle.copyWith(color: Colors.green[900])
              : headerStyle,
        ),
      ),
    );
    columns.add(col('Total', style: headerStyle));

    List<DataRow> rows = [];
    for (final p in players) {
      final cells = <DataCell>[DataCell(Text(p))];
      int total = 0;
      for (final h in holes) {
        final v = _scores[p]?[h];
        if (v == null) {
          cells.add(DataCell(Text('-'), onTap: () => _editCell(p, h)));
        } else {
          final b = best[h];
          final diff = (b != null) ? (v - b) : 0;
          total += v;
          final text = diff == 0 ? '$v' : '$v (${diff > 0 ? '+' : ''}$diff)';
          final cellChild = Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            decoration: BoxDecoration(
              color: h == _currentHole
                  ? Colors.greenAccent.withAlpha((0.25 * 255).round())
                  : null,
              borderRadius: h == _currentHole ? BorderRadius.circular(4) : null,
            ),
            child: Text(
              text,
              style: h == _currentHole
                  ? const TextStyle(fontWeight: FontWeight.bold)
                  : null,
            ),
          );
          cells.add(DataCell(cellChild, onTap: () => _editCell(p, h)));
        }
      }
      cells.add(DataCell(Text('$total')));
      rows.add(DataRow(cells: cells));
    }

    if (players.isEmpty) {
      return const Text('Nenhum jogador conectado ainda.');
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(columns: columns, rows: rows),
    );
  }
}
