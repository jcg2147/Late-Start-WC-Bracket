# Deploy from GitHub Actions

Use this workflow when the Supabase CLI cannot run locally:

```text
.github/workflows/deploy-sync-match-results.yml
```

It deploys:

```text
supabase/functions/sync-match-results
```

It also sets the Edge Function secrets before deploying.

## Required GitHub repository secrets

Add these in GitHub:

```text
Repository -> Settings -> Secrets and variables -> Actions -> New repository secret
```

### `SUPABASE_ACCESS_TOKEN`

Find/create it in Supabase:

```text
Supabase Dashboard -> Account -> Access Tokens
```

Create a personal access token and paste it into the GitHub secret.

### `SUPABASE_PROJECT_REF`

Find it in Supabase:

```text
Supabase Dashboard -> Project Settings -> General -> Reference ID
```

It is also the first subdomain in your project URL:

```text
https://<project-ref>.supabase.co
```

### `SYNC_MATCH_RESULTS_SECRET`

Create a long random value. Use the same value for:

- the Edge Function secret
- the scheduled GitHub workflow that invokes the function

Example:

```text
generate-a-long-random-value
```

### `WORLDCUP2026_API_BASE_URL`

Use:

```text
https://worldcup26.ir
```

## Manual deploy

In GitHub:

```text
Actions -> Deploy sync-match-results -> Run workflow
```

The workflow:

1. installs the Supabase CLI in the GitHub runner
2. sets `SYNC_MATCH_RESULTS_SECRET`
3. sets `WORLDCUP2026_API_BASE_URL`
4. deploys `sync-match-results` with `--no-verify-jwt`

JWT verification is disabled at the Supabase gateway because the function uses its own `SYNC_MATCH_RESULTS_SECRET` check.
