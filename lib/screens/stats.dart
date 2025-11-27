import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import '../models/game.dart';

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('games');
    final games = box.values.toList().cast<Map>().map((m) => Game.fromMap(m)).toList();

    final count = games.length;
    final scores = games.map((g) => g.score).where((s) => s != null).map((s) => s!).toList();
    final avg = scores.isNotEmpty ? scores.reduce((a, b) => a + b) / scores.length : 0.0;
    final best = scores.isNotEmpty ? scores.reduce((a, b) => a < b ? a : b) : 0;
    final latest = count > 0 ? (games..sort((a, b) => b.date.compareTo(a.date))).first : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Estatísticas')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Jogos registados: $count', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('Média de score: ${avg.toStringAsFixed(2)}'),
            const SizedBox(height: 8),
            Text('Melhor score: $best'),
            const SizedBox(height: 8),
            if (latest != null) Text('Último jogo: ${DateFormat.yMMMd().format(latest.date)} — ${latest.course} (${latest.score ?? '-'} )'),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: games.length,
                itemBuilder: (context, index) {
                  final g = games[index];
                  return ListTile(
                    title: Text('${g.course} — ${g.score}'),
                    subtitle: Text(DateFormat.yMMMd().format(g.date)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
