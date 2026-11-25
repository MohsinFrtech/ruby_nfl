# One team's games in one season (regular season only), from that team's point of view:
# who they play, home or away, the score and W/L/T. Cached per team AND season.
#
# The raw answer is about 320 KB (every game repeats both teams' 17 logos and 14 links);
# ours keeps one small entry per game.
class NflTeamSchedule
  # The season is not one we can have a schedule for.
  class UnknownSeason < StandardError; end

  # The API's seasons start at 2002 (same limit as GET /standings/:year).
  FIRST_SEASON = 2002

  # How long a copy is used depends on the games inside it (like GET /schedule):
  # A game is on. Longer than /schedule's 2 minutes on purpose: this is one call per team,
  # so 2 minutes could cost ~100 calls per team per game. Live scores for every game are
  # what GET /schedule is for.
  LIVE_TTL = 15.minutes
  UPCOMING_MIN_TTL = 2.minutes
  UPCOMING_MAX_TTL = 8.hours # kickoff times can still change
  FINISHED_TTL = 7.days      # every game is over: nothing will change
  LATE_PRE_LIMIT = 6.hours   # a game still "pre" this long after kickoff is not live (postponed...)
  STALE_GRACE = 3.days       # if the API is down, serve the old schedule up to 3 days past expiry

  def self.cache_key(team_id, season)
    "nfl/team_schedule/v1/#{team_id}/#{season}"
  end

  # The NFL season that is on now. A season starts in September and ends in early February,
  # so in January and February it is still last year's season. Worked out from the date, so
  # it costs no call and cannot fail.
  def self.current_season(now = Time.current.utc)
    now.month < 3 ? now.year - 1 : now.year
  end

  # The method our controller will call. `season` is optional (nil or "" = current season).
  #
  # The team and the season are both checked FIRST, so a made-up id or year never reaches
  # RapidAPI and never creates a cache entry. And the team and season INSIDE the answer must
  # be the ones we asked for, or nothing is cached (a backup is served if there is one).
  def self.for(team_id, season = nil)
    team = NflTeams.find!(team_id) # raises NflTeams::UnknownTeam for a made-up id
    season = season.presence&.to_s || current_season.to_s
    raise UnknownSeason, "bad season #{season.inspect}" unless valid_season?(season)

    StaleCache.fetch(cache_key(team[:id], season), expires_in: ->(data) { fresh_for(data[:games]) },
                                                   grace: STALE_GRACE) do
      schedule = from_api(NflApiClient.new.team_schedule(team[:id], season))
      ensure_requested(schedule, team[:id], season)

      { fetched_at: Time.current.utc.iso8601 }.merge(schedule)
    end
  end

  # raw: the parsed JSON Hash from NflApiClient#team_schedule
  # returns: { season:, season_type:, team:, bye_week:, games: [...] } (games in date order)
  def self.from_api(raw)
    raw = object(raw)
    team = object(raw["team"])
    season = object(raw["requestedSeason"]).presence || object(raw["season"])

    {
      season: season["year"],
      season_type: season["name"], # "Regular Season"
      team: {
        id: team["id"].presence&.to_s,
        name: team["displayName"],
        abbreviation: team["abbreviation"],
        color: ("##{team["color"]}" if team["color"].is_a?(String) && team["color"].present?),
        logo: team["logo"],
        logo_dark: team["logoDark"],
        record: team["recordSummary"],    # "3-8"
        standing: team["standingSummary"] # "4th in NFC West"
      },
      bye_week: raw["byeWeek"].is_a?(Integer) ? raw["byeWeek"] : nil,
      games: Array(raw["events"]).filter_map { |event| format_game(event, team["id"].to_s) if event.is_a?(Hash) }
                                 .sort_by { |game| game[:date].to_s }
    }
  end

  # One game, seen from our team's side (`team_id`).
  def self.format_game(event, team_id)
    competition = object(Array(event["competitions"]).first)
    status = object(object(competition["status"])["type"])
    competitors = Array(competition["competitors"]).select { |c| c.is_a?(Hash) }
    us = competitors.find { |c| object(c["team"])["id"].to_s == team_id } || {}
    them = (competitors - [ us ]).first || {}
    opponent = object(them["team"])
    venue = object(competition["venue"])

    {
      id: event["id"],
      week: object(event["week"])["number"],
      date: event["date"],
      name: event["name"],                       # "Arizona Cardinals at Los Angeles Chargers"
      short_name: event["shortName"],            # "ARI @ LAC"
      status: status["state"],                   # "pre", "in" or "post"
      status_detail: status["detail"],           # "Final", "Final/OT", "Sun, November 29th at 4:25 PM EST"
      home_away: us["homeAway"],                 # our team: "home" or "away"
      opponent: { id: opponent["id"], name: opponent["displayName"], abbreviation: opponent["abbreviation"] },
      score: score(us),                          # nil until the game starts
      opponent_score: score(them),
      result: result(status, us, them),          # "W", "L", "T", or nil if not finished
      venue: venue["fullName"],
      city: object(venue["address"])["city"],
      broadcasts: Array(competition["broadcasts"]).filter_map { |b| object(object(b)["media"])["shortName"].presence }
    }
  end

  def self.score(competitor)
    value = object(competitor["score"])["value"]
    value.is_a?(Numeric) ? value.to_i : nil
  end

  def self.result(status, us, them)
    return nil unless status["completed"] == true && score(us) && score(them)
    return "W" if us["winner"] == true
    return "L" if them["winner"] == true

    "T" # finished, scores known, nobody won
  end

  # --- cache lifetime ----------------------------------------------------------
  # A game on -> LIVE_TTL. Every game over -> FINISHED_TTL. Otherwise until the next
  # kickoff (so the cache refreshes as that game starts), between 2 minutes and 8 hours.
  def self.fresh_for(games, now = Time.current)
    games = Array(games)
    return LIVE_TTL if games.any? { |game| live?(game, now) }
    return FINISHED_TTL if games.any? && games.all? { |game| game[:status] == "post" }

    next_kickoff = games.filter_map do |game|
      kickoff = kickoff_time(game)
      kickoff if game[:status] == "pre" && kickoff && kickoff > now
    end.min
    return UPCOMING_MAX_TTL if next_kickoff.nil?

    (next_kickoff - now).to_f.clamp(UPCOMING_MIN_TTL.to_i, UPCOMING_MAX_TTL.to_i).round.seconds
  end

  # "in", or still "pre" although kickoff has passed (the API is often a little late).
  def self.live?(game, now)
    return true if game[:status] == "in"

    kickoff = kickoff_time(game)
    game[:status] == "pre" && !kickoff.nil? && kickoff <= now && kickoff > now - LATE_PRE_LIMIT
  end

  def self.kickoff_time(game)
    Time.iso8601(game[:date].to_s.sub(/(T\d{2}:\d{2})Z\z/, '\1:00Z'))
  rescue ArgumentError
    nil
  end

  # --- checks --------------------------------------------------------------------

  def self.valid_season?(season)
    season.match?(/\A20\d{2}\z/) && season.to_i.between?(FIRST_SEASON, current_season)
  end

  # Another team or another season than we asked for: never cache it under this key.
  def self.ensure_requested(schedule, team_id, season)
    unless schedule.dig(:team, :id) == team_id && schedule[:season] == season.to_i
      raise NflApiClient::Error,
            "NFL API sent team #{schedule.dig(:team, :id).inspect} season #{schedule[:season].inspect}, " \
            "expected team #{team_id} season #{season}"
    end
    raise NflApiClient::Error, "NFL API team schedule had no games" if schedule[:games].empty?
  end

  # The value if it is an object (Hash), otherwise an empty one, so a null or a stray
  # string where an object belongs reads as "missing" instead of crashing with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  private_class_method :format_game, :score, :result, :live?, :kickoff_time,
                       :valid_season?, :ensure_requested, :object
end
