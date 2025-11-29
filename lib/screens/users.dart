import 'package:flutter/material.dart';
import '../services/api.dart';
import 'login.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late Future<List<Map<String, dynamic>>> _usersFuture;
  bool? _autoUpdateEnabled;
  String _updateLog = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final current = Api.currentUser();
    if (current == null || (current['role'] as String?) != 'admin') {
      // Avoid calling the admin-only endpoint when not an admin.
      setState(() {
        _usersFuture = Future.error('Requires admin (please login as admin)');
      });
      _loadAdminState();
      return;
    }
    setState(() {
      _usersFuture = Api.listUsers();
    });
    _loadAdminState();
  }

  Future<void> _showCreate() async {
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String role = 'viewer';
    final res = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Criar utilizador'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Nome'),
            ),
            TextField(
              controller: passCtrl,
              decoration: const InputDecoration(labelText: 'Senha'),
              obscureText: true,
            ),
            DropdownButton<String>(
              value: role,
              items: const [
                DropdownMenuItem(value: 'admin', child: Text('admin')),
                DropdownMenuItem(value: 'editor', child: Text('editor')),
                DropdownMenuItem(value: 'player', child: Text('player')),
                DropdownMenuItem(value: 'viewer', child: Text('viewer')),
              ],
              onChanged: (v) => role = v ?? 'viewer',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, {
              'name': nameCtrl.text.trim(),
              'password': passCtrl.text,
              'role': role,
            }),
            child: const Text('Criar'),
          ),
        ],
      ),
    );
    if (res != null) {
      try {
        await Api.createUser(res['name'], res['password'], role: res['role']);
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Utilizador criado')));
        _load();
      } catch (e) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    }
  }

  Future<void> _revoke(int id) async {
    try {
      final newKey = await Api.revokeUser(id);
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Nova API key'),
          content: SelectableText(newKey),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fechar'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      _load();
    } catch (e) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(SnackBar(content: Text('Erro: $e')));
    }
  }

  Future<void> _loadAdminState() async {
    try {
      final enabled = await Api.getAutoUpdate();
      final log = await Api.getUpdateLog();
      if (!mounted) return;
      setState(() {
        _autoUpdateEnabled = enabled;
        _updateLog = log;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _autoUpdateEnabled = null;
        _updateLog = 'Unable to fetch server log or status.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestão de Utilizadores')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Erro: ${snapshot.error}'));
          }
          final users = snapshot.data ?? [];
          final current = Api.currentUser();
          final isAdmin =
              current != null && (current['role'] as String?) == 'admin';
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        current != null
                            ? 'Logado como: ${current['name']} (${current['role']})'
                            : 'Não autenticado',
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        if (current == null) {
                          final res = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const LoginScreen(),
                            ),
                          );
                          if (res != null) {
                            if (!mounted) return;
                            _load();
                          }
                        } else {
                          await Api.logout();
                          if (!mounted) return;
                          _load();
                        }
                      },
                      child: Text(current == null ? 'Login' : 'Logout'),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: _showCreate,
                child: const Text('Criar novo utilizador'),
              ),
              const SizedBox(height: 8),
              if (isAdmin)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Auto updates (server)'),
                        subtitle: _autoUpdateEnabled == null
                            ? const Text('estado não carregado')
                            : null,
                        value: _autoUpdateEnabled ?? false,
                        onChanged: _autoUpdateEnabled == null
                            ? null
                            : (v) async {
                                try {
                                  final newVal = await Api.setAutoUpdate(v);
                                  if (!mounted) return;
                                  setState(() => _autoUpdateEnabled = newVal);
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Auto-update setting updated',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!mounted) return;
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Erro: $e')),
                                  );
                                }
                              },
                      ),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: () async {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('Confirmar trigger update'),
                                  content: const Text(
                                    'Isto irá forçar o backend a atualizar e reiniciar (servidor ficará temporariamente indisponível). Continuar?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancelar'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Sim'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                              try {
                                final res = await Api.triggerUpdate();
                                if (!mounted) return;
                                // ignore: use_build_context_synchronously
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Update iniciado: ${res['message'] ?? ''}',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                // ignore: use_build_context_synchronously
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Erro: $e')),
                                );
                              }
                            },
                            child: const Text('Trigger Update'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: () async {
                              try {
                                final log = await Api.getUpdateLog();
                                if (!mounted) return;
                                setState(() => _updateLog = log);
                              } catch (e) {
                                if (!mounted) return;
                                // ignore: use_build_context_synchronously
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Erro: $e')),
                                );
                              }
                            },
                            child: const Text('Atualizar Log'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, idx) {
                    final u = users[idx];
                    return ListTile(
                      title: Text(u['name'] ?? ''),
                      subtitle: Text('role: ${u['role'] ?? ''}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.vpn_key),
                        onPressed: () => _revoke(u['id'] as int),
                      ),
                    );
                  },
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Backend update.log',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 180,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(_updateLog),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
