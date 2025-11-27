import 'package:flutter/material.dart';
import '../services/api.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  late Future<List<Map<String, dynamic>>> _usersFuture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() => _usersFuture = Api.listUsers());
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
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nome')),
            TextField(controller: passCtrl, decoration: const InputDecoration(labelText: 'Senha'), obscureText: true),
            DropdownButton<String>(value: role, items: const [DropdownMenuItem(value: 'admin', child: Text('admin')), DropdownMenuItem(value: 'editor', child: Text('editor')), DropdownMenuItem(value: 'player', child: Text('player')), DropdownMenuItem(value: 'viewer', child: Text('viewer'))], onChanged: (v) => role = v ?? 'viewer'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, {'name': nameCtrl.text.trim(), 'password': passCtrl.text, 'role': role}), child: const Text('Criar')),
        ],
      ),
    );
    if (res != null) {
      try {
        await Api.createUser(res['name'], res['password'], role: res['role']);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Utilizador criado')));
        _load();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    }
  }

  Future<void> _revoke(int id) async {
    try {
      final newKey = await Api.revokeUser(id);
      await showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Nova API key'), content: SelectableText(newKey), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar'))]));
      _load();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gestão de Utilizadores')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          if (snapshot.hasError) return Center(child: Text('Erro: ${snapshot.error}'));
          final users = snapshot.data ?? [];
          return Column(
            children: [
              ElevatedButton(onPressed: _showCreate, child: const Text('Criar novo utilizador')),
              Expanded(
                child: ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, idx) {
                    final u = users[idx];
                    return ListTile(
                      title: Text(u['name'] ?? ''),
                      subtitle: Text('role: ${u['role'] ?? ''}'),
                      trailing: IconButton(icon: const Icon(Icons.vpn_key), onPressed: () => _revoke(u['id'] as int)),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
