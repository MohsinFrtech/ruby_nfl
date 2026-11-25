# The players of one team. Turns the raw list into a small, consistent shape
# and caches it per team.
class NflTeamPlayers
  CACHE_TTL = 24.hours # rosters change when players are signed, cut or traded
  STALE_GRACE = 3.days # if the API is down, serve the old roster up to 3 days past expiry

  # One cache entry PER TEAM, e.g. "nfl/team_players/v1/29".
  def self.cache_key(team_id)
    "nfl/team_players/v1/#{team_id}"
  end

  # The method our controller will call. An unknown team id raises
  # NflTeams::UnknownTeam before anything else happens (see NflTeams.find!).
  def self.for(team_id)
    team = NflTeams.find!(team_id)

    StaleCache.fetch(cache_key(team[:id]), expires_in: CACHE_TTL, grace: STALE_GRACE) do
      {
        fetched_at: Time.current.utc.iso8601,
        team: team.slice(:id, :name, :abbreviation, :logo),
        players: from_api(NflApiClient.new.team_players(team[:id]))
      }
    end
  end

  # raw: the parsed JSON Hash from NflApiClient#team_players
  # returns: an Array of players, in the order the API sends them (by last name)
  # A broken entry (not an object, or no player id) is skipped instead of crashing
  # the request: without an id, a player could never be opened with /players/:id.
  def self.from_api(raw)
    players = raw.is_a?(Hash) ? raw["data"] : nil
    return [] unless players.is_a?(Array)

    players.filter_map do |player|
      next unless player.is_a?(Hash) && player["playerId"].present?

      {
        id: player["playerId"],
        name: player["fullName"],
        first_name: player["firstName"],
        last_name: player["lastName"],
        short_name: player["shortName"],
        url: player["link"]
      }
    end
  end
end
