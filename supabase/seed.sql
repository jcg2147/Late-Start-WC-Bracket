-- ============================================================
-- World Cup Bracket Challenge — Match Seed Data
-- Run AFTER schema.sql.
-- All times stored as UTC. Scoreboard state as of Jun 28, 2026.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- ROUND OF 32  (matches 73–88)
-- round_points = 1 each
-- home_source_match_id / away_source_match_id = NULL (teams come from group stage)
-- ─────────────────────────────────────────────────────────────

INSERT INTO matches
  (id, round, match_number, home_team, away_team,
   home_score, away_score, winner, is_completed,
   scheduled_at, venue, round_points)
VALUES

-- Match 73 ── COMPLETED: Canada 1–0 South Africa
(73, 'R32', 1,
 'South Africa', 'Canada',
 0, 1, 'Canada', TRUE,
 '2026-06-28 19:00:00+00',
 'SoFi Stadium, Inglewood, CA', 1),

-- Match 74 ── Germany vs Paraguay  (Jun 29, 4:30 PM ET)
(74, 'R32', 2,
 'Germany', 'Paraguay',
 NULL, NULL, NULL, FALSE,
 '2026-06-29 20:30:00+00',
 'Gillette Stadium, Foxborough, MA', 1),

-- Match 75 ── Netherlands vs Morocco  (Jun 29, 9 PM CDT local → 02:00 UTC Jun 30)
(75, 'R32', 3,
 'Netherlands', 'Morocco',
 NULL, NULL, NULL, FALSE,
 '2026-06-30 02:00:00+00',
 'Estadio Akron, Guadalupe, Nuevo León, Mexico', 1),

-- Match 76 ── Brazil vs Japan  (Jun 29, 1 PM ET)
(76, 'R32', 4,
 'Brazil', 'Japan',
 NULL, NULL, NULL, FALSE,
 '2026-06-29 17:00:00+00',
 'NRG Stadium, Houston, TX', 1),

-- Match 77 ── France vs Sweden  (Jun 30, 5 PM ET)
(77, 'R32', 5,
 'France', 'Sweden',
 NULL, NULL, NULL, FALSE,
 '2026-06-30 21:00:00+00',
 'MetLife Stadium, East Rutherford, NJ', 1),

-- Match 78 ── Ivory Coast vs Norway  (Jun 30, 1 PM ET)
(78, 'R32', 6,
 'Ivory Coast', 'Norway',
 NULL, NULL, NULL, FALSE,
 '2026-06-30 17:00:00+00',
 'AT&T Stadium, Arlington, TX', 1),

-- Match 79 ── Mexico vs Ecuador  (Jun 30, 9 PM CDT → 02:00 UTC Jul 1)
(79, 'R32', 7,
 'Mexico', 'Ecuador',
 NULL, NULL, NULL, FALSE,
 '2026-07-01 02:00:00+00',
 'Estadio Azteca, Mexico City, Mexico', 1),

-- Match 80 ── England vs Congo DR  (Jul 1, 12 PM ET)
(80, 'R32', 8,
 'England', 'Congo DR',
 NULL, NULL, NULL, FALSE,
 '2026-07-01 16:00:00+00',
 'Mercedes-Benz Stadium, Atlanta, GA', 1),

-- Match 81 ── USA vs Bosnia-Herzegovina  (Jul 1, 8 PM ET)
(81, 'R32', 9,
 'USA', 'Bosnia-Herzegovina',
 NULL, NULL, NULL, FALSE,
 '2026-07-02 00:00:00+00',
 'Levi''s Stadium, Santa Clara, CA', 1),

-- Match 82 ── Belgium vs Senegal  (Jul 1, 4 PM ET)
(82, 'R32', 10,
 'Belgium', 'Senegal',
 NULL, NULL, NULL, FALSE,
 '2026-07-01 20:00:00+00',
 'Lumen Field, Seattle, WA', 1),

-- Match 83 ── Portugal vs Croatia  (Jul 2, 7 PM ET)
(83, 'R32', 11,
 'Portugal', 'Croatia',
 NULL, NULL, NULL, FALSE,
 '2026-07-02 23:00:00+00',
 'BMO Field, Toronto, Canada', 1),

-- Match 84 ── Spain vs Austria  (Jul 2, 3 PM ET)
(84, 'R32', 12,
 'Spain', 'Austria',
 NULL, NULL, NULL, FALSE,
 '2026-07-02 19:00:00+00',
 'SoFi Stadium, Inglewood, CA', 1),

-- Match 85 ── Switzerland vs Algeria  (Jul 2, 11 PM ET)
(85, 'R32', 13,
 'Switzerland', 'Algeria',
 NULL, NULL, NULL, FALSE,
 '2026-07-03 03:00:00+00',
 'BC Place, Vancouver, Canada', 1),

-- Match 86 ── Argentina vs Cape Verde  (Jul 3, 6 PM ET)
(86, 'R32', 14,
 'Argentina', 'Cape Verde',
 NULL, NULL, NULL, FALSE,
 '2026-07-03 22:00:00+00',
 'Hard Rock Stadium, Miami Gardens, FL', 1),

-- Match 87 ── Colombia vs Ghana  (Jul 3, ~9 PM ET)
(87, 'R32', 15,
 'Colombia', 'Ghana',
 NULL, NULL, NULL, FALSE,
 '2026-07-04 01:00:00+00',
 'Arrowhead Stadium, Kansas City, MO', 1),

-- Match 88 ── Australia vs Egypt  (Jul 3, 2 PM ET)
(88, 'R32', 16,
 'Australia', 'Egypt',
 NULL, NULL, NULL, FALSE,
 '2026-07-03 18:00:00+00',
 'AT&T Stadium, Arlington, TX', 1);


-- ─────────────────────────────────────────────────────────────
-- ROUND OF 16  (matches 89–96)
-- round_points = 2 each
-- home_team / away_team are NULL until source matches complete,
-- EXCEPT Match 90 where Canada is already known.
-- ─────────────────────────────────────────────────────────────

INSERT INTO matches
  (id, round, match_number,
   home_team, away_team,
   home_source_match_id, away_source_match_id,
   scheduled_at, venue, round_points)
VALUES

-- Match 89 ── Winner(74) vs Winner(77)  (Jul 4, 5 PM ET)
(89, 'R16', 1,
 NULL, NULL,
 74, 77,
 '2026-07-04 21:00:00+00',
 'TBD', 2),

-- Match 90 ── Canada vs Winner(75)  (Jul 4, 1 PM ET)
-- Canada is already confirmed; away team TBD from Match 75
(90, 'R16', 2,
 'Canada', NULL,
 73, 75,
 '2026-07-04 17:00:00+00',
 'NRG Stadium, Houston, TX', 2),

-- Match 91 ── Winner(76) vs Winner(78)  (Jul 5, 4 PM ET)
(91, 'R16', 3,
 NULL, NULL,
 76, 78,
 '2026-07-05 20:00:00+00',
 'TBD', 2),

-- Match 92 ── Winner(79) vs Winner(80)  (Jul 5, 8 PM ET)
(92, 'R16', 4,
 NULL, NULL,
 79, 80,
 '2026-07-06 00:00:00+00',
 'TBD', 2),

-- Match 93 ── Winner(83) vs Winner(84)  (Jul 6, 3 PM ET)
(93, 'R16', 5,
 NULL, NULL,
 83, 84,
 '2026-07-06 19:00:00+00',
 'TBD', 2),

-- Match 94 ── Winner(81) vs Winner(82)  (Jul 6, 8 PM ET)
(94, 'R16', 6,
 NULL, NULL,
 81, 82,
 '2026-07-07 00:00:00+00',
 'TBD', 2),

-- Match 95 ── Winner(86) vs Winner(88)  (Jul 7, 12 PM ET)
(95, 'R16', 7,
 NULL, NULL,
 86, 88,
 '2026-07-07 16:00:00+00',
 'TBD', 2),

-- Match 96 ── Winner(85) vs Winner(87)  (Jul 7, 4 PM ET)
(96, 'R16', 8,
 NULL, NULL,
 85, 87,
 '2026-07-07 20:00:00+00',
 'TBD', 2);


-- ─────────────────────────────────────────────────────────────
-- QUARTERFINALS  (matches 97–100)
-- round_points = 4 each
-- ─────────────────────────────────────────────────────────────

INSERT INTO matches
  (id, round, match_number,
   home_source_match_id, away_source_match_id,
   scheduled_at, venue, round_points)
VALUES

-- Match 97 ── Winner(89) vs Winner(90)  (Jul 9, 4 PM ET)
(97, 'QF', 1, 89, 90, '2026-07-09 20:00:00+00', 'TBD', 4),

-- Match 98 ── Winner(93) vs Winner(94)  (Jul 10, 3 PM ET)
(98, 'QF', 2, 93, 94, '2026-07-10 19:00:00+00', 'TBD', 4),

-- Match 99 ── Winner(91) vs Winner(92)  (Jul 11, 5 PM ET)
(99, 'QF', 3, 91, 92, '2026-07-11 21:00:00+00', 'TBD', 4),

-- Match 100 ── Winner(95) vs Winner(96)  (Jul 11, 9 PM ET)
(100, 'QF', 4, 95, 96, '2026-07-12 01:00:00+00', 'TBD', 4);


-- ─────────────────────────────────────────────────────────────
-- SEMIFINALS  (matches 101–102)
-- round_points = 8 each
-- ─────────────────────────────────────────────────────────────

INSERT INTO matches
  (id, round, match_number,
   home_source_match_id, away_source_match_id,
   scheduled_at, venue, round_points)
VALUES

-- Match 101 ── Winner(97) vs Winner(98)  (Jul 14, 3 PM ET)
(101, 'SF', 1, 97, 98, '2026-07-14 19:00:00+00', 'TBD', 8),

-- Match 102 ── Winner(99) vs Winner(100)  (Jul 15, 3 PM ET)
(102, 'SF', 2, 99, 100, '2026-07-15 19:00:00+00', 'TBD', 8);


-- ─────────────────────────────────────────────────────────────
-- THIRD-PLACE MATCH  (match 103)
-- round_points = 4
-- Sources are the LOSERS of both semi-finals
-- ─────────────────────────────────────────────────────────────

INSERT INTO matches
  (id, round, match_number,
   home_source_match_id, away_source_match_id,
   home_source_is_loser, away_source_is_loser,
   scheduled_at, venue, round_points)
VALUES
(103, '3P', 1,
 101, 102,
 TRUE, TRUE,
 '2026-07-18 15:00:00+00',
 'MetLife Stadium, East Rutherford, NJ', 4);


-- ─────────────────────────────────────────────────────────────
-- FINAL  (match 104)
-- round_points = 16
-- ─────────────────────────────────────────────────────────────

INSERT INTO matches
  (id, round, match_number,
   home_source_match_id, away_source_match_id,
   scheduled_at, venue, round_points)
VALUES
(104, 'F', 1,
 101, 102,
 '2026-07-19 19:00:00+00',
 'MetLife Stadium, East Rutherford, NJ', 16);
