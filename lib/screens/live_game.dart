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
  const LiveGameScreen({super.key, required this.gameId, required this.course, this.holes = 18});

  @override
  State<LiveGameScreen> createState() => _LiveGameScreenState();
}

class _LiveGameScreenState extends State<LiveGameScreen> {
  late WebSocketChannel _channel;
  final List<String> _events = [];
  StreamSubscription? _sub;
  int _currentHole = 1;
  int _strokesToAdd = 1;
  // player -> hole -> strokes
  final Map<String, Map<int, int>> _scores = {};

  @override
  void initState() {
    super.initState();
    // load cached scores if present
    try {
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
    } catch (_) {}
    _channel = Api.wsForGame(widget.gameId);
    _sub = _channel.stream.listen((data) {
      try {
        final msg = data is String ? jsonDecode(data) : data;
        if (msg is Map && msg['type'] == 'stroke') {
          final player = msg['player_name'] as String? ?? 'Unknown';
          final hole = (msg['hole_number'] as num?)?.toInt() ?? 1;
          final strokes = (msg['strokes'] as num?)?.toInt() ?? 1;
          setState(() {
            final p = _scores.putIfAbsent(player, () => <int, int>{});
            p[hole] = (p[hole] ?? 0) + strokes;
            final ts = msg['ts'] ?? '';
            _events.insert(0, '$ts $player: hole $hole -> $strokes');
          });
        } else {
          setState(() => _events.insert(0, data.toString()));
        }
      } catch (e) {
        setState(() => _events.insert(0, 'WS parse error: $e'));
      }
    }, onError: (e) {
      setState(() => _events.insert(0, 'WS error: $e'));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel.sink.close();
    super.dispose();
  }

  Future<void> _addStroke() async {
    // For demo: add a fixed stroke event
    try {
      await Api.addStroke(widget.gameId, 'Jogador', _currentHole, _strokesToAdd);
      if (!mounted) return;
      setState(() {
        final p = _scores.putIfAbsent('Jogador', () => <int, int>{});
        p[_currentHole] = (p[_currentHole] ?? 0) + _strokesToAdd;
        _events.insert(0, 'Enviado: Jogador: hole $_currentHole -> $_strokesToAdd');
      });
      _saveCache();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stroke enviado')));
      // auto-advance hole and initialize zeros; if holes == 0 we treat as dynamic (no upper bound)
      final shouldAdvance = widget.holes == 0 || _currentHole < widget.holes;
      if (shouldAdvance) {
        final newHole = _currentHole + 1;
        setState(() {
          _currentHole = newHole;
          _strokesToAdd = 1;
          for (final p in _scores.keys) {
            _scores[p] = _scores[p] ?? <int, int>{};
            _scores[p]![newHole] = _scores[p]![newHole] ?? 0;
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro: $e')));
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
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancelar')),
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tacadas atualizadas')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao actualizar: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Live — ${widget.course}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
            child: Row(
              children: [
                Text('Buraco: $_currentHole / ${widget.holes == 0 ? '?' : widget.holes}'),
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
                  onPressed: () {
                    final newHole = _currentHole + 1;
                    setState(() {
                      _currentHole = newHole;
                      _strokesToAdd = 1;
                      for (final p in _scores.keys) {
                        _scores[p] = _scores[p] ?? <int, int>{};
                        _scores[p]![newHole] = _scores[p]![newHole] ?? 0;
                      }
                    });
                  },
                ),
                const Spacer(),
                Text('Tacadas: $_strokesToAdd'),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _strokesToAdd > 1 ? () => setState(() => _strokesToAdd--) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => setState(() => _strokesToAdd++),
                ),
              ],
            ),
          ),
          ElevatedButton(onPressed: _addStroke, child: const Text('Adicionar stroke')),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Jogo: ${widget.course}   Buraco atual: $_currentHole', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _buildScoreTable(),
                  const SizedBox(height: 12),
                  const Text('Eventos (últimos primeiro):'),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _events.length,
                    itemBuilder: (context, index) => ListTile(title: Text(_events[index])),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScoreTable() {
    final players = _scores.keys.toList()..sort();
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

    DataColumn col(String label, {TextStyle? style}) => DataColumn(label: Text(label, style: style));

    final headerStyle = TextStyle(fontWeight: FontWeight.bold);
    final columns = <DataColumn>[col('Player', style: headerStyle)];
    columns.addAll(holes.map((h) => col('$h', style: h == _currentHole ? headerStyle.copyWith(color: Colors.green[900]) : headerStyle)));
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
              color: h == _currentHole ? Colors.greenAccent.withAlpha((0.25 * 255).round()) : null,
              borderRadius: h == _currentHole ? BorderRadius.circular(4) : null,
            ),
            child: Text(text, style: h == _currentHole ? const TextStyle(fontWeight: FontWeight.bold) : null),
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
