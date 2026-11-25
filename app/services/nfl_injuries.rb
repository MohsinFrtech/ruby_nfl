# Turns the raw injuries response (32 teams, 500+ injuries, lots of internal
# fields) into the clean, grouped-by-team list that our own endpoint returns.
class NflInjuries
  CACHE_KEY = "nfl/injuries/v1".freeze
  CACHE_TTL = 8.hours
  STALE_GRACE = 1.day # if the API is down, serve the old report up to 1 day past expiry

  # The method our controller will call. Returns the teams plus the time they
  # were fetched, so API users can see how old the data is.
  def self.latest
    StaleCache.fetch(CACHE_KEY, expires_in: CACHE_TTL, grace: STALE_GRACE) do
      teams = from_api(NflApiClient.new.injuries)
      # No teams at all is a bad answer (a team with no injuries is fine). Never cache it as
      # "nobody is injured" for 8 hours: fail, so the backup is served instead.
      raise NflApiClient::Error, "NFL API injuries had no teams" if teams.empty?

      { fetched_at: Time.current.utc.iso8601, teams: teams }
    end
  end

  # raw: the parsed JSON Hash from NflApiClient#injuries
  # returns: an Array of teams (same order as the API), each with its injuries
  # A team or injury that is not an object (null, text...) is skipped instead of crashing.
  def self.from_api(raw)
    teams = raw.is_a?(Hash) ? raw["data"] : nil
    return [] unless teams.is_a?(Array)

    teams.select { |team| team.is_a?(Hash) }.map do |team|
      {
        team: team["displayName"],
        logo: team["logo"],
        injuries: Array(team["items"]).select { |item| item.is_a?(Hash) }.map { |item| format_injury(item) }
      }
    end
  end

  def self.format_injury(item)
    athlete = object(item["athlete"])

    {
      player: athlete["name"],
      player_id: player_id(athlete["href"]),          # for GET /players/:id
      position: athlete["position"],
      status: item["statusDesc"],                      # "Questionable", "Out", "Injured Reserve"...
      status_code: object(item["type"])["abbreviation"], # "Q", "O", "IR"...
      comment: item["description"].presence,           # often blank -> nil
      date: item["date"],                              # text like "Nov 15" (the API gives no year)
      url: athlete["href"],
      headshot: object(athlete["logo"])["href"]
    }
  end

  # The API gives no player id, but its player link holds one:
  # ".../nfl/player/_/id/3886633/hjalte-froholdt" -> "3886633". nil when there is none.
  def self.player_id(href)
    href.to_s[%r{/id/([1-9]\d{0,9})(?:/|\z)}, 1]
  end

  # The value if it is an object (Hash), otherwise an empty one, so a null or a stray
  # string where an object belongs reads as "missing" instead of crashing with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  private_class_method :format_injury, :player_id, :object
end
