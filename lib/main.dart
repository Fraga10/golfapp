import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'screens/home.dart';
import 'services/api.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load environment variables from .env (optional). Put API_BASE_URL here.
  try {
    await dotenv.load();
  } catch (_) {}
  await Hive.initFlutter();
  await Hive.openBox('games');
  await Hive.openBox('live_cache');
  await Hive.openBox('auth');
  await Api.loadAuthFromStorage();
  // Print resolved API base URL to help diagnose network issues
  try {
    debugPrint('Resolved API_BASE_URL=${Api.baseUrl}');
  } catch (_) {}
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Golfe - Registro de Jogos',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
