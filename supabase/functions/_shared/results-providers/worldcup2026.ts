import type { CompletedFixtureResult, ResultsProvider } from './types.ts';

type WorldCup2026Game = {
  id?: string | number;
  home_team_name_en?: string;
  away_team_name_en?: string;
  home_score?: string | number | null;
  away_score?: string | number | null;
  finished?: string | boolean | null;
  type?: string;
  winner?: string | null;
  winner_team_name_en?: string | null;
  penalty_winner?: string | null;
  shootout_winner?: string | null;
  home_penalty_score?: string | number | null;
  away_penalty_score?: string | number | null;
};

type WorldCup2026Response = {
  games?: WorldCup2026Game[];
};

const PROVIDER_NAME = 'worldcup2026';
const TEAM_NAME_ALIASES: Record<string, string> = {
  'democratic republic of the congo': 'Congo DR',
};

export function createWorldCup2026Provider(): ResultsProvider {
  const baseUrl = Deno.env.get('WORLDCUP2026_API_BASE_URL') ?? 'https://worldcup26.ir';

  return {
    name: PROVIDER_NAME,
    async fetchFixtures(): Promise<CompletedFixtureResult[]> {
      const url = new URL('/get/games', baseUrl);
      const response = await fetch(url);

      if (!response.ok) {
        const body = await response.text();
        throw new Error(`WorldCup2026 API request failed: ${response.status} ${body}`);
      }

      const payload = await response.json() as WorldCup2026Game[] | WorldCup2026Response;
      const games = Array.isArray(payload) ? payload : payload.games;

      if (!Array.isArray(games)) {
        throw new Error('WorldCup2026 API response did not include a games array');
      }

      return games.map(normalizeGame);
    },
  };
}

function normalizeGame(game: WorldCup2026Game): CompletedFixtureResult {
  const externalMatchId = String(game.id ?? '').trim();
  const internalMatchId = Number.parseInt(externalMatchId, 10);
  const homeTeamName = canonicalTeamName(String(game.home_team_name_en ?? '').trim());
  const awayTeamName = canonicalTeamName(String(game.away_team_name_en ?? '').trim());
  const completed = isFinished(game.finished);
  const homeScore = parseScore(game.home_score);
  const awayScore = parseScore(game.away_score);
  const homePenaltyScore = parseScore(game.home_penalty_score);
  const awayPenaltyScore = parseScore(game.away_penalty_score);
  const shootoutWinner = firstNonEmpty(
    game.shootout_winner,
    game.penalty_winner,
    game.winner_team_name_en,
    game.winner,
  ) ?? detectPenaltyWinner(homeTeamName, awayTeamName, homePenaltyScore, awayPenaltyScore);
  const winnerName = detectWinner(homeTeamName, awayTeamName, homeScore, awayScore, shootoutWinner);
  const skipReason = completed && !winnerName
    ? 'Completed match has tied score and no shootout winner or decisive penalty score.'
    : undefined;

  return {
    provider: PROVIDER_NAME,
    externalMatchId,
    internalMatchId,
    homeTeamName,
    awayTeamName,
    homeScore,
    awayScore,
    homePenaltyScore,
    awayPenaltyScore,
    completed,
    winnerName,
    rawStatus: String(game.finished ?? ''),
    skipReason,
  };
}

function isFinished(value: WorldCup2026Game['finished']): boolean {
  if (typeof value === 'boolean') return value;
  return String(value ?? '').trim().toLowerCase() === 'true';
}

function parseScore(value: WorldCup2026Game['home_score']): number | null {
  if (value === null || value === undefined || value === '') return null;
  const score = Number(value);
  return Number.isInteger(score) ? score : null;
}

function detectWinner(
  homeTeamName: string,
  awayTeamName: string,
  homeScore: number | null,
  awayScore: number | null,
  shootoutWinner: string | null,
): string | null {
  if (homeScore === null || awayScore === null) return null;
  if (homeScore > awayScore) return homeTeamName;
  if (awayScore > homeScore) return awayTeamName;
  return normalizeWinnerName(shootoutWinner, homeTeamName, awayTeamName);
}

function detectPenaltyWinner(
  homeTeamName: string,
  awayTeamName: string,
  homePenaltyScore: number | null,
  awayPenaltyScore: number | null,
): string | null {
  if (homePenaltyScore === null || awayPenaltyScore === null) return null;
  if (homePenaltyScore > awayPenaltyScore) return homeTeamName;
  if (awayPenaltyScore > homePenaltyScore) return awayTeamName;
  return null;
}

function normalizeWinnerName(winner: string | null, homeTeamName: string, awayTeamName: string): string | null {
  if (!winner) return null;

  const normalizedWinner = normalizeName(canonicalTeamName(winner));
  if (normalizedWinner === normalizeName(homeTeamName)) return homeTeamName;
  if (normalizedWinner === normalizeName(awayTeamName)) return awayTeamName;
  return null;
}

function canonicalTeamName(value: string): string {
  const trimmed = value.trim();
  return TEAM_NAME_ALIASES[normalizeName(trimmed)] ?? trimmed;
}

function normalizeName(value: string): string {
  return value.trim().toLowerCase();
}

function firstNonEmpty(...values: Array<string | null | undefined>): string | null {
  for (const value of values) {
    const trimmed = String(value ?? '').trim();
    if (trimmed) return trimmed;
  }

  return null;
}
