# Late Start World Cup Bracket

A private World Cup knockout bracket challenge for friends.

Players sign in with Google, complete one bracket, and lock it permanently. As official World Cup results come in, standings update from the saved picks and official winners.

## Features

- Google sign-in with Supabase Auth
- One locked bracket submission per user
- Interactive knockout bracket from Round of 32 through the Final
- Third-Place Match and Final goals tiebreaker
- Automatic scoring from official winners
- Current Standings leaderboard
- Server-side match result sync from the WorldCup2026 API

## Local Development

This is a static frontend and can be served with any local static server.

```powershell
cd C:\Users\juanc\Downloads\late-start-bracket
python -m http.server 8000 --bind 127.0.0.1
```

Open:

```text
http://127.0.0.1:8000/
```

The frontend configuration lives in:

```text
js/config.js
```

Use only the public Supabase URL and anon/publishable key there. Do not put service-role keys or sports API secrets in frontend files.

## GitHub Pages Deployment

The app is designed for GitHub Pages.

Recommended setup:

1. Push the repo to GitHub.
2. Go to `Settings -> Pages`.
3. Deploy from the `main` branch.
4. In Supabase Auth settings, add your GitHub Pages URL as an allowed redirect URL.

## Supabase Architecture

Core tables:

- `matches`: official knockout match data and result state
- `users`: lightweight participant profile rows
- `submissions`: one locked bracket per user
- `picks`: saved predictions for each submitted bracket
- `scores`: calculated leaderboard totals

Important SQL phases:

- `supabase/schema.sql`
- `supabase/seed.sql`
- `supabase/phase3_auth_submission.sql`
- `supabase/phase4_scoring_leaderboard.sql`
- `supabase/phase5_match_result_workflow.sql`
- `supabase/phase6_automatic_result_sync.sql`
- `supabase/phase8_custom_usernames.sql`

Run these in Supabase SQL Editor in order when setting up a new project.

## Automatic Result Sync

The Edge Function is:

```text
supabase/functions/sync-match-results
```

It fetches:

```text
https://worldcup26.ir/get/games
```

The WorldCup2026 API match IDs match the internal `matches.id`, so the sync validates team names and then calls:

```sql
public.record_match_result(match_id, winner, 'worldcup2026')
```

That RPC is the single place that updates winners, advances teams, and recalculates scores.

### Deploy Edge Function from GitHub Actions

Use:

```text
.github/workflows/deploy-sync-match-results.yml
```

Required GitHub repository secrets:

- `SUPABASE_ACCESS_TOKEN`
- `SUPABASE_PROJECT_REF`
- `SYNC_MATCH_RESULTS_SECRET`
- `WORLDCUP2026_API_BASE_URL`

The scheduled sync workflow is:

```text
.github/workflows/sync-match-results.yml
```

It runs every 30 minutes and calls the deployed Edge Function.

## Manual Result Fallback

If automatic sync misses a result, record it manually in Supabase SQL Editor:

```sql
select public.record_match_result(74, 'Germany');
```

Manual results set `manual_override = true`, so automatic sync will not overwrite them.

## Security Notes

- Service-role keys stay server-side only.
- The sports result sync secret is stored in Supabase/GitHub secrets, not frontend code.
- Regular users can read match data and leaderboard-safe standings.
- Regular users cannot edit official results or scores.
