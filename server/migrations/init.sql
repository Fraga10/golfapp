-- Initial schema for Golfe server
CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  api_key TEXT UNIQUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS games (
  id SERIAL PRIMARY KEY,
  course TEXT NOT NULL,
  date TIMESTAMPTZ NOT NULL,
  holes INT NOT NULL DEFAULT 18,
  status TEXT NOT NULL DEFAULT 'pending', -- pending|active|finished
  created_by INT REFERENCES users(id),
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS game_players (
  id SERIAL PRIMARY KEY,
  game_id INT REFERENCES games(id) ON DELETE CASCADE,
  player_name TEXT NOT NULL,
  player_id INT,
  handicap INT
);

CREATE TABLE IF NOT EXISTS strokes (
  id SERIAL PRIMARY KEY,
  game_id INT REFERENCES games(id) ON DELETE CASCADE,
  player_name TEXT NOT NULL,
  hole_number INT NOT NULL,
  strokes INT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);
