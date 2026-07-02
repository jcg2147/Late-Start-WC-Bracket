import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { createWorldCup2026Provider } from '../_shared/results-providers/worldcup2026.ts';
import type { CompletedFixtureResult, InternalMatch } from '../_shared/results-providers/types.ts';

type SyncSummary = {
  provider: string;
  version: string;
  matchesChecked: number;
  matchesUpdated: number;
  scoresUpdated: number;
  matchesSkipped: number;
  unmatched: Array<{
    externalMatchId: string;
    matchId?: number;
    reason: string;
  }>;
  errors: string[];
  updated: Array<{
    matchId: number;
    externalMatchId: string;
    winner: string;
    homeScore: number | null;
    awayScore: number | null;
    homePenaltyScore: number | null;
    awayPenaltyScore: number | null;
    message: string;
  }>;
  skipped: Array<{
    externalMatchId: string;
    matchId?: number;
    reason: string;
  }>;
};

const jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
};

const SYNC_FUNCTION_VERSION = 'worldcup2026-score-sync-v5';
const TEAM_NAME_ALIASES: Record<string, string> = {
  'democratic republic of the congo': 'congo dr',
};

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return json({ error: 'Use POST to sync match results.' }, 405);
  }

  try {
    authorizeRequest(request);

    const provider = createWorldCup2026Provider();
    const supabaseUrl = requiredEnv('SUPABASE_URL');
    const serviceRoleKey = requiredEnv('SUPABASE_SERVICE_ROLE_KEY');
    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        persistSession: false,
      },
    });

    const fixtures = await provider.fetchFixtures();
    const matchIds = [
      ...new Set(
        fixtures
          .filter((fixture) => fixture.completed)
          .map((fixture) => fixture.internalMatchId)
          .filter(Number.isInteger),
      ),
    ];
    let internalMatches: InternalMatch[] = [];

    if (matchIds.length > 0) {
      const { data, error: matchError } = await supabase
        .from('matches')
        .select('id, home_team, away_team, home_score, away_score, winner, is_completed, external_provider, external_match_id, manual_override')
        .in('id', matchIds);

      if (matchError) throw matchError;
      internalMatches = data ?? [];
    }

    const matchesById = new Map(
      (internalMatches ?? []).map((match: InternalMatch) => [match.id, match]),
    );

    const summary: SyncSummary = {
      provider: provider.name,
      version: SYNC_FUNCTION_VERSION,
      matchesChecked: fixtures.length,
      matchesUpdated: 0,
      scoresUpdated: 0,
      matchesSkipped: 0,
      unmatched: [],
      errors: [],
      updated: [],
      skipped: [],
    };

    for (const fixture of fixtures) {
      await syncFixture(supabase, fixture, matchesById, summary);
    }

    return json(summary);
  } catch (error) {
    if (error instanceof UnauthorizedError) {
      return json({ error: error.message }, 401);
    }

    return json({
      error: error instanceof Error ? error.message : String(error),
    }, 500);
  }
});

class UnauthorizedError extends Error {}

function authorizeRequest(request: Request) {
  const expectedSecret = requiredEnv('SYNC_MATCH_RESULTS_SECRET');
  const authHeader = request.headers.get('authorization') ?? '';
  const bearerToken = authHeader.startsWith('Bearer ') ? authHeader.slice('Bearer '.length) : '';
  const headerToken = request.headers.get('x-sync-secret') ?? '';

  if (bearerToken !== expectedSecret && headerToken !== expectedSecret) {
    throw new UnauthorizedError('Unauthorized sync request');
  }
}

async function syncFixture(
  supabase: ReturnType<typeof createClient>,
  fixture: CompletedFixtureResult,
  matchesById: Map<number, InternalMatch>,
  summary: SyncSummary,
) {
  if (!fixture.completed) {
    skip(summary, fixture.externalMatchId, 'Fixture is not finished.');
    return;
  }

  if (!Number.isInteger(fixture.internalMatchId)) {
    unmatched(summary, fixture, 'API id is not a valid internal match id.');
    return;
  }

  const match = matchesById.get(fixture.internalMatchId);

  if (!match) {
    unmatched(summary, fixture, 'No internal match found for API id.');
    return;
  }

  if (match.manual_override) {
    skip(summary, fixture.externalMatchId, 'Manual override is set.', match.id);
    return;
  }

  const teamValidationError = validateTeams(match, fixture);
  if (teamValidationError) {
    unmatched(summary, fixture, teamValidationError, match.id);
    return;
  }

  if (!fixture.winnerName) {
    skip(summary, fixture.externalMatchId, fixture.skipReason ?? `Completed fixture has no winner. Status: ${fixture.rawStatus ?? 'unknown'}.`, match.id);
    return;
  }

  if (match.is_completed && match.winner === fixture.winnerName) {
    const scoreUpdate = await updateMatchScores(supabase, match.id, fixture);
    if (scoreUpdate.error) {
      summary.errors.push(`Match ${match.id} / fixture ${fixture.externalMatchId}: ${scoreUpdate.error.message}`);
      return;
    }

    summary.scoresUpdated += 1;
    skip(summary, fixture.externalMatchId, `Internal match already has this winner; score synced as ${scoreUpdate.homeScore}-${scoreUpdate.awayScore}.`, match.id);

    return;
  }

  const { data, error } = await supabase.rpc('record_match_result', {
    match_id_input: match.id,
    winner_team_input: fixture.winnerName,
    result_source_input: fixture.provider,
  });

  if (error) {
    summary.errors.push(`Match ${match.id} / fixture ${fixture.externalMatchId}: ${error.message}`);
    return;
  }

  if (data?.skipped) {
    skip(summary, fixture.externalMatchId, data.message ?? 'RPC skipped match.', match.id);
    return;
  }

  const scoreUpdate = await updateMatchScores(supabase, match.id, fixture);
  if (scoreUpdate.error) {
    summary.errors.push(`Match ${match.id} / fixture ${fixture.externalMatchId}: ${scoreUpdate.error.message}`);
    return;
  }

  summary.scoresUpdated += 1;
  summary.matchesUpdated += 1;
  summary.updated.push({
    matchId: match.id,
    externalMatchId: fixture.externalMatchId,
    winner: fixture.winnerName,
    homeScore: fixture.homeScore,
    awayScore: fixture.awayScore,
    homePenaltyScore: fixture.homePenaltyScore,
    awayPenaltyScore: fixture.awayPenaltyScore,
    message: data?.message ?? 'Updated.',
  });
}

async function updateMatchScores(
  supabase: ReturnType<typeof createClient>,
  matchId: number,
  fixture: CompletedFixtureResult,
): Promise<{ homeScore: number; awayScore: number; error: null } | { homeScore: null; awayScore: null; error: Error }> {
  if (!Number.isInteger(fixture.homeScore) || !Number.isInteger(fixture.awayScore)) {
    return {
      homeScore: null,
      awayScore: null,
      error: new Error('Completed fixture is missing integer scores.'),
    };
  }

  const { data, error } = await supabase
    .from('matches')
    .update({
      home_score: fixture.homeScore,
      away_score: fixture.awayScore,
      home_penalty_score: fixture.homePenaltyScore,
      away_penalty_score: fixture.awayPenaltyScore,
      external_provider: fixture.provider,
      external_match_id: fixture.externalMatchId,
      result_source: fixture.provider,
      last_synced_at: new Date().toISOString(),
    })
    .eq('id', matchId)
    .eq('manual_override', false)
    .select('id, home_score, away_score')
    .maybeSingle();

  if (error) {
    return {
      homeScore: null,
      awayScore: null,
      error: new Error(error.message),
    };
  }

  if (!data) {
    return {
      homeScore: null,
      awayScore: null,
      error: new Error('Score update did not match a writable row. Check manual_override and match id.'),
    };
  }

  return {
    homeScore: data.home_score,
    awayScore: data.away_score,
    error: null,
  };
}

function skip(summary: SyncSummary, externalMatchId: string, reason: string, matchId?: number) {
  summary.matchesSkipped += 1;
  summary.skipped.push({ externalMatchId, matchId, reason });
}

function unmatched(summary: SyncSummary, fixture: CompletedFixtureResult, reason: string, matchId?: number) {
  summary.matchesSkipped += 1;
  summary.unmatched.push({
    externalMatchId: fixture.externalMatchId,
    matchId,
    reason,
  });
}

function validateTeams(match: InternalMatch, fixture: CompletedFixtureResult): string | null {
  if (normalizeName(match.home_team) !== normalizeName(fixture.homeTeamName)) {
    return `Home team mismatch. Internal: "${match.home_team ?? 'TBD'}"; API: "${fixture.homeTeamName}".`;
  }

  if (normalizeName(match.away_team) !== normalizeName(fixture.awayTeamName)) {
    return `Away team mismatch. Internal: "${match.away_team ?? 'TBD'}"; API: "${fixture.awayTeamName}".`;
  }

  return null;
}

function normalizeName(value: string | null): string {
  const normalized = String(value ?? '').trim().toLowerCase();
  return TEAM_NAME_ALIASES[normalized] ?? normalized;
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing ${name} secret`);
  return value;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: jsonHeaders,
  });
}
