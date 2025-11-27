class Game {
  final int id;
  final DateTime date;
  final String course;
  final int? score;
  final int holes;
  final String? notes;

  Game({
    required this.id,
    required this.date,
    required this.course,
    required this.score,
    required this.holes,
    this.notes,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'course': course,
      'score': score,
      'holes': holes,
      'notes': notes,
    };
  }

  factory Game.fromMap(Map<dynamic, dynamic> map) {
    return Game(
      id: map['id'] as int,
      date: DateTime.parse(map['date'] as String),
      course: map['course'] as String,
      score: map.containsKey('score') ? (map['score'] as num).toInt() : null,
      holes: (map['holes'] as num).toInt(),
      notes: map['notes'] as String?,
    );
  }
}
