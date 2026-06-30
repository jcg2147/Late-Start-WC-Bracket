export type InternalMatch = {
  id: number;
  home_team: string | null;
  away_team: string | null;
  home_score: number | null;
  away_score: number | null;
  winner: string | null;
  is_completed: boolean;
  external_provider: string | null;
  external_match_id: string | null;
  manual_override: boolean;
};

export type CompletedFixtureResult = {
  provider: string;
  externalMatchId: string;
  internalMatchId: number;
  homeTeamName: string;
  awayTeamName: string;
  homeScore: number | null;
  awayScore: number | null;
  homePenaltyScore: number | null;
  awayPenaltyScore: number | null;
  completed: boolean;
  winnerName: string | null;
  rawStatus: string | null;
  skipReason?: string;
};

export type ResultsProvider = {
  name: string;
  fetchFixtures(): Promise<CompletedFixtureResult[]>;
};
