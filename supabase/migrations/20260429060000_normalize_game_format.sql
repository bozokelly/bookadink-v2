-- Normalize game_format to canonical values and enforce via CHECK constraint.
-- game_format is a PG enum column — cast to ::TEXT for WHERE comparisons.
-- Canonical set: open_play, random, round_robin, king_of_court, dupr_king_of_court
-- Legacy values being retired:
--   ladder          → king_of_court  (old alias, same format)
--   singles/doubles → open_play      (these belong in game_type, not game_format)

UPDATE games
SET game_format = 'king_of_court'
WHERE game_format::TEXT = 'ladder';

UPDATE games
SET game_format = 'open_play'
WHERE game_format::TEXT IN ('singles', 'doubles');

ALTER TABLE games
ADD CONSTRAINT games_game_format_valid
CHECK (game_format::TEXT IN ('open_play', 'random', 'round_robin', 'king_of_court', 'dupr_king_of_court'));
