import 'package:flutter/material.dart';
import '../services/api.dart';

class AddGameScreen extends StatefulWidget {
  const AddGameScreen({super.key});

  @override
  State<AddGameScreen> createState() => _AddGameScreenState();
}

class _AddGameScreenState extends State<AddGameScreen> {
  final _formKey = GlobalKey<FormState>();
  DateTime _date = DateTime.now();
  final _scoreCtrl = TextEditingController();
  final _holesCtrl = TextEditingController(text: '18');
  int _selectedHoles = 18;
  bool _customHoles = false;
  final _notesCtrl = TextEditingController();
  final _playersCtrl = TextEditingController();
  // store per-player per-hole strokes when building a past game
  final Map<String, Map<int, int>> _playerStrokes = {};
  String _gameMode = 'standard';
  String _gameFlow = 'live';

  @override
  void dispose() {
    _scoreCtrl.dispose();
    _holesCtrl.dispose();
    _playersCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Create remotely via API
    try {
      final players = <Map<String, dynamic>>[];
      final isPast = _gameFlow == 'import';
      if (isPast && _playersCtrl.text.trim().isNotEmpty) {
        final names = _playersCtrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
        for (final n in names) {
          final playerMap = <String, dynamic>{'player_name': n};
          final strokes = _playerStrokes[n];
          if (strokes != null && strokes.isNotEmpty) {
            playerMap['strokes'] = Map.fromEntries(strokes.entries.map((e) => MapEntry(e.key.toString(), e.value)));
          }
          players.add(playerMap);
        }
      }
      final status = isPast ? 'finished' : 'active';
      final holes = isPast ? (int.tryParse(_holesCtrl.text) ?? _selectedHoles) : null;
      // Course is auto-derived from selected mode
      final courseName = _gameMode == 'pitch' ? 'Pitch & Putt' : 'Standard';
      final createdAt = DateTime.now();
      final id = await Api.createGame(
        courseName,
        createdAt,
        holes: holes,
        status: status,
        players: players.isNotEmpty ? players : null,
        mode: _gameMode,
        flow: _gameFlow,
      );
      if (!mounted) return;
      Navigator.pop(context, id);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao criar jogo: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adicionar Jogo')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              ListTile(
                title: Text('Data: ${_date.toLocal().toString().split('.').first}'),
                trailing: IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute));
                  },
                ),
              ),
              // Course is derived from selected mode; 'Jogo passado' is implied by Flow == 'import'
              Row(
                children: [
                  Expanded(child: Text('Tipo:')),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<String>(
                          initialValue: _gameMode,
                          decoration: const InputDecoration(labelText: 'Modo de Jogo'),
                          items: const [
                            DropdownMenuItem(value: 'standard', child: Text('Standard')),
                            DropdownMenuItem(value: 'pitch', child: Text('Pitch & Putt')),
                          ],
                          onChanged: (v) => setState(() => _gameMode = v ?? 'standard'),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          initialValue: _gameFlow,
                          decoration: const InputDecoration(labelText: 'Fluxo'),
                          items: const [
                            DropdownMenuItem(value: 'live', child: Text('Live')),
                            DropdownMenuItem(value: 'import', child: Text('Import')),
                          ],
                          onChanged: (v) => setState(() => _gameFlow = v ?? 'live'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_gameFlow == 'import')
                TextFormField(
                  controller: _scoreCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Resultado (score)'),
                ),
              if (_gameFlow == 'import')
                TextFormField(
                  controller: _playersCtrl,
                  decoration: const InputDecoration(labelText: 'Jogadores (separar por vírgula)'),
                ),
              if (_gameFlow == 'import') DropdownButtonFormField<int>(
                initialValue: _customHoles ? null : _selectedHoles,
                decoration: const InputDecoration(labelText: 'Buracos'),
                items: const [
                  DropdownMenuItem(value: 9, child: Text('9')),
                  DropdownMenuItem(value: 18, child: Text('18')),
                  DropdownMenuItem(value: 0, child: Text('Outro')),
                ],
                onChanged: (v) {
                  setState(() {
                    if (v == null) return;
                    if (v == 0) {
                      _customHoles = true;
                    } else {
                      _customHoles = false;
                      _selectedHoles = v;
                      _holesCtrl.text = v.toString();
                    }
                  });
                },
              ),
              if (_gameFlow == 'import' && _customHoles)
                TextFormField(
                  controller: _holesCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Buracos (custom)'),
                ),
              if (_gameFlow == 'import' && (_playersCtrl.text.trim().isNotEmpty))
                Padding(
                  padding: const EdgeInsets.only(top: 12.0),
                  child: ElevatedButton(
                    onPressed: () async {
                      final names = _playersCtrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
                      if (names.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Insira pelo menos um jogador')));
                        return;
                      }
                      final holes = int.tryParse(_holesCtrl.text) ?? _selectedHoles;
                      for (final name in names) {
                        _playerStrokes.putIfAbsent(name, () => <int, int>{});
                      }
                      await showDialog<void>(
                        context: context,
                        builder: (_) => Dialog(
                          child: SizedBox(
                            width: 800,
                            height: 400,
                            child: Padding(
                              padding: const EdgeInsets.all(12.0),
                              child: Column(
                                children: [
                                  Text('Editar scores por buraco', style: Theme.of(context).textTheme.titleLarge),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: ListView.builder(
                                      itemCount: names.length,
                                      itemBuilder: (context, idx) {
                                        final player = names[idx];
                                        return ExpansionTile(
                                          title: Text(player),
                                          children: [
                                            SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: Row(
                                                children: List.generate(holes, (hIdx) {
                                                  final holeNum = hIdx + 1;
                                                  final ctrl = TextEditingController(text: _playerStrokes[player]?[holeNum]?.toString() ?? '');
                                                  return Padding(
                                                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                                                    child: SizedBox(
                                                      width: 64,
                                                      child: TextField(
                                                        controller: ctrl,
                                                        keyboardType: TextInputType.number,
                                                        decoration: InputDecoration(labelText: '$holeNum'),
                                                        onChanged: (val) {
                                                          final v = int.tryParse(val) ?? 0;
                                                          _playerStrokes[player] = _playerStrokes[player] ?? <int, int>{};
                                                          if (v > 0) {
                                                            _playerStrokes[player]![holeNum] = v;
                                                          } else {
                                                            _playerStrokes[player]!.remove(holeNum);
                                                          }
                                                        },
                                                      ),
                                                    ),
                                                  );
                                                }),
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                          ],
                                        );
                                      },
                                    ),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
                                    ],
                                  )
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Editar scores por buraco'),
                  ),
                ),
              TextFormField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notas (opcional)'),
                maxLines: 3,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _save,
                child: const Text('Guardar'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
