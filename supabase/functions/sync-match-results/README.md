# sync-match-results

Server-side automatic result sync for the World Cup bracket app.

Default provider:

```text
GET https://worldcup26.ir/get/games
```

Flow:

1. The Edge Function fetches WorldCup2026 games.
2. Completed games are normalized by `worldcup2026.ts`.
3. API `id` is converted to an integer and matched directly to `matches.id`.
4. Home and away team names are validated before any update.
5. The function skips unfinished, tied-without-shootout-winner-or-penalty-score, mismatched, already-recorded, and `manual_override = true` matches.
6. New completed results call `public.record_match_result(match_id_input, winner_team_input, 'worldcup2026')`.
7. `record_match_result` advances teams and calls `recalculate_scores()`.
8. The Edge Function stores the provider's integer `home_score`, `away_score`, `home_penalty_score`, and `away_penalty_score` on the matching `matches` row.

## Required secrets

```bash
supabase secrets set SYNC_MATCH_RESULTS_SECRET="generate-a-long-random-value"
```

Optional:

```bash
supabase secrets set WORLDCUP2026_API_BASE_URL="https://worldcup26.ir"
```

Supabase provides `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in the Edge Function environment.

No sports API key is required.

## Deploy

```bash
supabase functions deploy sync-match-results
```

## Invoke manually

```bash
curl -X POST \
  "https://<project-ref>.supabase.co/functions/v1/sync-match-results" \
  -H "Authorization: Bearer <SYNC_MATCH_RESULTS_SECRET>"
```

Expected response:

```json
{
  "provider": "worldcup2026",
  "version": "worldcup2026-score-sync-v5",
  "matchesChecked": 1,
  "matchesUpdated": 1,
  "scoresUpdated": 1,
  "matchesSkipped": 0,
  "unmatched": [],
  "errors": [],
  "updated": [],
  "skipped": []
}
```

## Manual overrides

Manual results still take priority:

```sql
select public.record_match_result(74, 'Germany');
```

That sets `manual_override = true`, and the sync function will skip the match.
