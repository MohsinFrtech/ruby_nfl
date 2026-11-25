# Turns the raw (deeply nested) NFL API response into the clean list
# of teams that our own endpoint returns.
class NflTeams
  # Raised when a team id is not one of the NFL teams we know about.
  class UnknownTeam < StandardError; end

  # "v1" lets us invalidate old cached data if we ever change the shape of a team.
  CACHE_KEY = "nfl/teams/v1".freeze
  CACHE_TTL = 7.days
  STALE_GRACE = 30.days # team lists barely change, so an old copy is still very useful

  # The method our controller will call. Serves from the cache when it can;
  # only on a miss (first call, or after 7 days) does it hit the real API.
  # If that call fails, it falls back to the last good copy.
  def self.all
    StaleCache.fetch(CACHE_KEY, expires_in: CACHE_TTL, grace: STALE_GRACE) do
      teams = from_api(NflApiClient.new.team_list)
      # An empty list must never be cached: for 7 days every team id would look unknown.
      raise NflApiClient::Error, "NFL API team list had no teams" if teams.empty?

      teams
    end
  end

  # Finds one team by id, or raises UnknownTeam. Used by every per-team endpoint
  # BEFORE it calls RapidAPI, so made-up ids never cost a request or a cache entry.
  # The id is compared as text, so 22 and "22" both work but "022" does not.
  def self.find!(team_id)
    all.find { |team| team[:id] == team_id.to_s } ||
      raise(UnknownTeam, "no team with id #{team_id.to_s.inspect}")
  end

  # raw: the parsed JSON Hash from NflApiClient#team_list
  # returns: an Array of 32 small Hashes
  # A broken entry (no team, or a team without an id) is skipped instead of crashing
  # the whole list. If every entry is broken the list is empty, and `all` refuses it.
  def self.from_api(raw)
    entries = raw.is_a?(Hash) ? raw.dig("sports", 0, "leagues", 0, "teams") : nil

    Array(entries).filter_map do |entry|
      team = entry["team"] if entry.is_a?(Hash)
      next unless team.is_a?(Hash) && team["id"].present?

      {
        id: team["id"],
        name: team["displayName"],
        abbreviation: team["abbreviation"],
        location: team["location"],
        nickname: team["nickname"],
        color: hex(team["color"]),
        logo: default_logo(team["logos"])
      }
    end
  end

  def self.hex(color)
    "##{color}" if color.present?
  end

  def self.default_logo(logos)
    Array(logos).find { |logo| logo.is_a?(Hash) && Array(logo["rel"]).include?("default") }&.dig("href")
  end

  private_class_method :hex, :default_logo
end
