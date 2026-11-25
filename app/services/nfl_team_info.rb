# Details of one team: who they are, their record, their stadium and their next game.
# The raw answer is about 21 KB (17 logos, 14 links, 24 record stats...); we keep the
# useful part in a small, consistent shape, and cache it per team.
class NflTeamInfo
  CACHE_TTL = 8.hours  # the record and the next game only change when a game finishes
  STALE_GRACE = 3.days # if the API is down, serve the old details up to 3 days past expiry

  # One cache entry PER TEAM, e.g. "nfl/team_info/v1/22".
  def self.cache_key(team_id)
    "nfl/team_info/v1/#{team_id}"
  end

  # The method our controller will call.
  #
  # The team id is checked against our own (cached) team list FIRST, so a made-up id
  # never reaches RapidAPI and never creates a cache entry. And the team INSIDE the
  # answer must be the one we asked for: caching another team's details under this
  # team's key would show the wrong team for 8 hours.
  def self.for(team_id)
    team = NflTeams.find!(team_id) # raises NflTeams::UnknownTeam for a made-up id

    StaleCache.fetch(cache_key(team[:id]), expires_in: CACHE_TTL, grace: STALE_GRACE) do
      info = from_api(NflApiClient.new.team_info(team[:id]))
      unless info.dig(:team, :id) == team[:id]
        raise NflApiClient::Error, "NFL API sent team #{info.dig(:team, :id).inspect}, expected #{team[:id]}"
      end

      { fetched_at: Time.current.utc.iso8601 }.merge(info)
    end
  end

  # raw: the parsed JSON Hash from NflApiClient#team_info
  # returns: { team:, standing:, record:, venue:, next_game: } (a missing part is nil)
  def self.from_api(raw)
    team = object(object(raw)["team"])

    {
      team: format_team(team),
      standing: team["standingSummary"].presence, # "4th in NFC West"
      record: format_record(object(team["record"])["items"]),
      venue: format_venue(object(team["franchise"])["venue"]),
      next_game: format_next_game(Array(team["nextEvent"]).first)
    }
  end

  def self.format_team(team)
    {
      id: team["id"].presence&.to_s,
      name: team["displayName"],
      abbreviation: team["abbreviation"],
      location: team["location"],
      nickname: team["nickname"],
      color: hex(team["color"]),
      alternate_color: hex(team["alternateColor"]),
      logo: logo(team["logos"], %w[full default]),
      logo_dark: logo(team["logos"], %w[full dark]),
      url: link(team["links"], "clubhouse") # the team's page on ESPN
    }
  end

  # --- record ----------------------------------------------------------------
  # The API sends a list of records: "total", "home" and "road", each a summary ("3-8")
  # plus a list of { name:, value: } stats. Only the total has the points and streak.
  BASIC_STATS = { wins: "wins", losses: "losses", ties: "ties", win_percent: "winPercent" }.freeze
  TOTAL_STATS = {
    games_played: "gamesPlayed",
    points_for: "pointsFor",
    points_against: "pointsAgainst",
    point_differential: "pointDifferential",
    avg_points_for: "avgPointsFor",
    avg_points_against: "avgPointsAgainst",
    streak: "streak",             # +2 = won the last 2, -3 = lost the last 3
    playoff_seed: "playoffSeed"
  }.freeze

  # returns: { total: {...}, home: {...}, road: {...} }, or nil when there is no record
  def self.format_record(items)
    by_type = Array(items).select { |item| item.is_a?(Hash) && item["type"].present? }.index_by { |item| item["type"] }

    record = {
      total: format_record_item(by_type["total"], BASIC_STATS.merge(TOTAL_STATS)),
      home: format_record_item(by_type["home"], BASIC_STATS),
      road: format_record_item(by_type["road"], BASIC_STATS)
    }
    record.values.any? ? record : nil
  end

  def self.format_record_item(item, wanted)
    return nil unless item.is_a?(Hash)

    # (first of each name, in case the API repeats one, as it does in the standings)
    stats = Array(item["stats"]).select { |stat| stat.is_a?(Hash) }
                                .each_with_object({}) { |stat, by_name| by_name[stat["name"]] ||= stat["value"] }

    { summary: item["summary"].presence }
      .merge(wanted.transform_values { |name| number(stats[name]) })
  end

  # --- venue -------------------------------------------------------------------
  def self.format_venue(venue)
    return nil unless venue.is_a?(Hash)

    address = object(venue["address"])
    images = Array(venue["images"]).select { |image| image.is_a?(Hash) }
    {
      id: venue["id"],
      name: venue["fullName"],
      city: address["city"],
      state: address["state"],
      country: address["country"],
      zip_code: address["zipCode"],
      indoor: venue["indoor"],
      grass: venue["grass"],
      image: images.reject { |image| Array(image["rel"]).include?("interior") }.first&.dig("href")
    }
  end

  # --- next game ---------------------------------------------------------------
  # nil when there is no next game (e.g. after the team's season is over).
  def self.format_next_game(event)
    return nil unless event.is_a?(Hash)

    competition = object(Array(event["competitions"]).first)
    status = object(object(competition["status"])["type"])
    venue = object(competition["venue"])

    {
      id: event["id"],
      name: event["name"],             # "Washington Commanders at Arizona Cardinals"
      short_name: event["shortName"],  # "WSH @ ARI"
      date: event["date"],
      season: object(event["season"])["year"],
      season_type: object(event["seasonType"])["name"], # "Regular Season"
      week: object(event["week"])["number"],
      status: status["state"],         # "pre" = not started yet
      status_detail: status["detail"], # "Sun, November 29th at 4:25 PM EST"
      venue: venue["fullName"],
      city: object(venue["address"])["city"],
      broadcasts: Array(competition["broadcasts"]).filter_map { |b| object(object(b)["media"])["shortName"].presence },
      teams: Array(competition["competitors"]).select { |c| c.is_a?(Hash) }.map do |competitor|
        team = object(competitor["team"])
        { id: team["id"], name: team["displayName"], abbreviation: team["abbreviation"],
          home_away: competitor["homeAway"] }
      end
    }
  end

  # --- helpers -----------------------------------------------------------------
  def self.hex(color)
    "##{color}" if color.is_a?(String) && color.present?
  end

  # The logo whose "rel" list is exactly `rel`, e.g. ["full", "default"].
  def self.logo(logos, rel)
    Array(logos).find { |logo| logo.is_a?(Hash) && Array(logo["rel"]) == rel }&.dig("href")
  end

  def self.link(links, rel)
    Array(links).find { |link| link.is_a?(Hash) && Array(link["rel"]).include?(rel) }&.dig("href")
  end

  # Whole numbers stay whole (3), others are rounded (0.27272728 -> 0.2727). Not a number -> nil.
  def self.number(value)
    return nil unless value.is_a?(Numeric)

    value == value.to_i ? value.to_i : value.round(4)
  end

  # The value if it is an object (Hash), otherwise an empty one, so a null or a stray
  # string where an object belongs reads as "missing" instead of crashing with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  private_class_method :format_team, :format_record, :format_record_item, :format_venue,
                       :format_next_game, :hex, :logo, :link, :number, :object
end
