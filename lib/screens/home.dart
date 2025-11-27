import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/game.dart';
import 'add_game.dart';
import 'stats.dart';
import '../services/api.dart';
import 'live_game.dart';
import 'login.dart';
import 'users.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<List<Map<String, dynamic>>> _gamesFuture;

  @override
  void initState() {
    super.initState();
    _loadGames();
  }

  void _loadGames() {
    setState(() {
      _gamesFuture = Api.getGames();
    });
  }

  Future<void> _confirmAndDelete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Apagar jogo?'),
        content: const Text('Tem a certeza que deseja apagar este jogo? Esta ação não pode ser desfeita.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Apagar')),
        ],
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      final success = await Api.deleteGame(id);
      if (!mounted) return;
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Jogo apagado')));
        _loadGames();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Falha ao apagar jogo')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Golfe — Meus Jogos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StatsScreen()),
            ),
          ),
          Builder(builder: (context) {
            final user = Api.currentUser();
            if (user == null) {
              return IconButton(
                icon: const Icon(Icons.login),
                onPressed: () async {
                  final u = await Navigator.push(context, MaterialPageRoute(builder: (_) => const LoginScreen()));
                  if (u != null) _loadGames();
                },
              );
            } else {
              return Row(children: [
                Padding(padding: const EdgeInsets.symmetric(horizontal: 8.0), child: Text(user['name'] ?? '', style: const TextStyle(fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.logout), onPressed: () async { await Api.logout(); setState((){}); _loadGames(); }),
                IconButton(icon: const Icon(Icons.manage_accounts), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UsersScreen())).then((_) => _loadGames())),
              ]);
            }
          }),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _gamesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Erro ao carregar jogos: ${snapshot.error}'));
          }
          final games = snapshot.data ?? [];
          if (games.isEmpty) return const Center(child: Text('Nenhum jogo registado ainda'));
          return ListView.separated(
            itemCount: games.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final map = games[index];
              final game = Game.fromMap(map);
              final status = map['status'] as String? ?? '';
              return ListTile(
                title: Text(game.course),
                subtitle: Text('${DateFormat.yMMMd().format(game.date)} • ${status == 'active' ? 'dinâmico' : '${game.holes} buracos'}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: () {
                        final dynamicHoles = status == 'active' ? 0 : game.holes;
                        Navigator.push(context, MaterialPageRoute(builder: (_) => LiveGameScreen(gameId: game.id, course: game.course, holes: dynamicHoles))).then((_) => _loadGames());
                      },
                    ),
                    Builder(builder: (context) {
                      final user = Api.currentUser();
                      final role = user != null ? (user['role'] as String? ?? 'viewer') : 'viewer';
                      final canDelete = (role == 'admin' || role == 'editor');
                      return IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: canDelete ? () => _confirmAndDelete(game.id) : null,
                        tooltip: canDelete ? 'Apagar' : 'Sem permissão',
                      );
                    }),
                  ],
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text(game.course),
                      content: Text('Data: ${DateFormat.yMMMd().add_jm().format(game.date)}\nBuracos: ${game.holes}'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AddGameScreen()),
          );
          _loadGames();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
