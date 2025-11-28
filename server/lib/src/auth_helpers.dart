import 'package:shelf/shelf.dart';
import 'db.dart';

// Extracted helper: get user from Authorization Bearer header (returns null if unauthenticated)
Future<Map<String, dynamic>?> userFromRequest(Request req) async {
  final auth = req.headers['authorization'];
  if (auth == null || !auth.toLowerCase().startsWith('bearer ')) return null;
  final token = auth.substring(7).trim();
  if (token.isEmpty) return null;
  final res = await DB.conn.query(
      'SELECT id, name, api_key, role FROM users WHERE api_key = @k',
      substitutionValues: {'k': token});
  if (res.isEmpty) return null;
  final row = res.first;
  return {
    'id': row[0],
    'name': row[1],
    'api_key': row[2],
    'role': row[3],
  };
}

// Convenience helper: check if a user map has at least one of the allowed roles
bool userHasRole(Map<String, dynamic>? user, List<String> allowed) {
  if (user == null) return false;
  final role = (user['role'] as String?) ?? 'viewer';
  return allowed.contains(role);
}
