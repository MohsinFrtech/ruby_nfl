# Statistics for one team. Turns the raw response (167 stats x 2 sides, lots of
# repeated text) into a smaller, consistent shape, and caches it per team.
class NflTeamStatistics
  CACHE_TTL = 24.hours # stats only change after a game (about once a week)
  STALE_GRACE = 3.days # if the API is down, serve the old numbers up to 3 days past expiry

  # One cache entry PER TEAM, e.g. "nfl/team_statistics/v1/24".
  def self.cache_key(team_id)
    "nfl/team_statistics/v1/#{team_id}"
  end

  # The method our controller will call.
  #
  # The team id is checked against our own (cached) team list FIRST. An unknown
  # id never reaches RapidAPI and never creates a cache entry, so nobody can
  # burn the quota or fill the cache with made-up ids.
  def self.for(team_id)
    team = NflTeams.find!(team_id) # raises NflTeams::UnknownTeam for a made-up id

    StaleCache.fetch(cache_key(team[:id]), expires_in: CACHE_TTL, grace: STALE_GRACE) do
      {
        fetched_at: Time.current.utc.iso8601,
        team: team.slice(:id, :name, :abbreviation, :logo)
      }.merge(from_api(NflApiClient.new.team_statistic(team[:id])))
    end
  end

  # raw: the parsed JSON Hash from NflApiClient#team_statistic
  # returns: { team_stats: [...], opponent_stats: [...] }
  def self.from_api(raw)
    raw = {} unless raw.is_a?(Hash)

    {
      team_stats: format_categories(raw.dig("stats", "categories"), ranked: false),
      opponent_stats: format_categories(raw["opponent"], ranked: true)
    }
  end

  # A broken category or stat (not an object) is skipped instead of crashing the request.
  def self.format_categories(categories, ranked:)
    Array(categories).filter_map do |category|
      next unless category.is_a?(Hash)

      {
        category: category["name"],
        label: category["displayName"],
        stats: Array(category["stats"]).filter_map { |stat| format_stat(stat, ranked: ranked) if stat.is_a?(Hash) }
      }
    end
  end

  # Only the opponent side carries a ranking, so only add rank keys there.
  def self.format_stat(stat, ranked:)
    formatted = {
      name: stat["name"],
      label: stat["displayName"],
      abbreviation: stat["abbreviation"],
      value: stat["value"],                       # a number, or nil when the API has none
      display: stat["displayValue"],              # always text, e.g. "1,417"
      per_game: round3(stat["perGameValue"])      # 59.93899917602539 -> 59.939
    }
    formatted.merge!(rank: stat["rank"], rank_label: stat["rankDisplayValue"]) if ranked
    formatted
  end

  # Only a real number is rounded; anything else (nil, or text the API sent by mistake) is nil.
  def self.round3(value)
    value.round(3) if value.is_a?(Numeric)
  end

  private_class_method :format_categories, :format_stat, :round3
end
