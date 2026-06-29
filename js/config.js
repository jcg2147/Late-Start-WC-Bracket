// ─────────────────────────────────────────────────────────────
// Supabase configuration
// Replace these two values with your project's credentials from:
//   Supabase Dashboard → Settings → API
// ─────────────────────────────────────────────────────────────

const SUPABASE_URL      = 'https://rkiqtqtuykyimbeifvwy.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_rfNBjqNKPOCw1JVBmv3qBQ_XzFt9iNl';

// ─────────────────────────────────────────────────────────────
// App constants
// ─────────────────────────────────────────────────────────────

const ROUND_LABELS = {
  R32: 'Round of 32',
  R16: 'Round of 16',
  QF:  'Quarterfinals',
  SF:  'Semifinals',
  '3P': '3rd Place',
  F:   'Final',
};

const ROUND_POINTS = {
  R32: 1,
  R16: 2,
  QF:  4,
  SF:  8,
  '3P': 4,
  F:   16,
};

// Matches that were completed before this challenge launched.
// Users receive no points for these; they are locked and pre-filled.
const PRE_CHALLENGE_MATCH_IDS = [73];
