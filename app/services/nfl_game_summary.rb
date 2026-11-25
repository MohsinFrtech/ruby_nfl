# Everything about ONE game: the teams and score by quarter, team and player box score,
# leaders, scoring plays, venue and officials. Cached per game.
#
# The raw answer is about 530 KB, three quarters of it play-by-play ("drives"). We leave
# out the play-by-play, the win-probability chart and the league standings, and keep the
# rest in a small, consistent shape (about 40 KB for a finished game).
class NflGameSummary
  # The game id is not a known NFL game.
  class UnknownGame < StandardError; end

  # How long a copy is used depends on the game itself:
  LIVE_TTL = 5.minutes      # the game is on (one call per game, so a little longer than /schedule)
  UPCOMING_MIN_TTL = 2.minutes
  UPCOMING_MAX_TTL = 8.hours  # not started: kickoff time or TV can still change
  FINISHED_TTL = 30.days      # a final box score does not change
  LATE_PRE_LIMIT = 6.hours    # still "pre" this long after kickoff: not live (postponed...)

  # If the API is down, serve the old copy this long past expiry. A finished game's copy is
  # still right however old; an unfinished one gets 1 day.
  FINISHED_GRACE = 30.days
  OTHER_GRACE = 1.day

  MISSING_TTL = 1.hour # remember "this id does not exist" so a fake id is not retried constantly

  # At most this many RapidAPI calls a day (UTC) for game summaries, about 4,500 a month
  # (see NflPlayerOverview::DAILY_LOOKUPS for how the two budgets fit the monthly quota).
  # Like player ids, any id that LOOKS valid costs a call, even a made-up one. Over the
  # budget, games already in the cache (or their backups) are still served.
  DAILY_LOOKUPS = 150

  # Real game ids are plain positive numbers (e.g. 401872926). Same rule as player ids:
  # no leading zeros, so one game can never end up with two cache entries.
  ID_FORMAT = /\A[1-9]\d{0,9}\z/

  def self.cache_key(game_id)
    "nfl/game_summary/v1/#{game_id}"
  end

  def self.missing_key(game_id)
    "nfl/game_summary/missing/v1/#{game_id}"
  end

  def self.budget_key(date = Time.current.utc.to_date)
    "nfl/game_summary/budget/v1/#{date.iso8601}"
  end

  # The method our controller will call.
  #
  # A badly formed id is refused without any call. An id the API says does not exist is
  # remembered for an hour. And the game INSIDE the answer must be the one we asked for.
  def self.for(game_id)
    id = game_id.to_s
    raise UnknownGame, "bad game id #{id.inspect}" unless id.match?(ID_FORMAT)
    raise UnknownGame, "no game with id #{id}" if Rails.cache.exist?(missing_key(id))

    StaleCache.fetch(cache_key(id), expires_in: ->(data) { fresh_for(data) },
                                    grace: ->(data) { finished?(data) ? FINISHED_GRACE : OTHER_GRACE }) do
      spend_lookup! # only reached when RapidAPI is really about to be called

      summary = from_api(NflApiClient.new.game_summary(id))
      raise NflApiClient::Error, "NFL API sent game #{summary[:id].inspect}, expected #{id}" unless summary[:id] == id

      { fetched_at: Time.current.utc.iso8601 }.merge(summary)
    end
  rescue NflApiClient::NotFound
    Rails.cache.write(missing_key(id), true, expires_in: MISSING_TTL)
    raise UnknownGame, "no game with id #{id}"
  end

  # Counts one RapidAPI call against today's budget, or refuses it if the budget is used up.
  def self.spend_lookup!
    used = Rails.cache.increment(budget_key, 1, expires_in: 2.days)
    return if used.nil? || used <= DAILY_LOOKUPS # nil: the cache could not count; do not block

    raise NflApiClient::BudgetExceeded, "game lookup budget of #{DAILY_LOOKUPS} a day is used up"
  end

  # raw: the parsed JSON Hash from NflApiClient#game_summary
  # returns: { id:, season:, week:, date:, status:, teams:, ... } (a part the API did not
  # send is nil or an empty list; a game that has not started has no box score yet)
  def self.from_api(raw)
    raw = object(raw)
    header = object(raw["header"])
    competition = object(Array(header["competitions"]).first)
    info = object(raw["gameInfo"])
    venue = object(info["venue"])
    status = object(object(competition["status"])["type"])

    {
      id: header["id"].presence&.to_s,
      season: object(header["season"])["year"],
      week: header["week"],
      date: competition["date"],
      status: { state: status["state"], detail: status["detail"], completed: status["completed"] == true },
      venue: venue.any? ? { name: venue["fullName"], city: object(venue["address"])["city"],
                            state: object(venue["address"])["state"], attendance: info["attendance"] } : nil,
      broadcasts: Array(competition["broadcasts"]).filter_map { |b| object(object(b)["media"])["shortName"].presence },
      teams: hashes(competition["competitors"]).map { |competitor| format_competitor(competitor) },
      team_stats: hashes(object(raw["boxScore"])["teams"]).map { |box| format_team_stats(box) },
      player_stats: hashes(object(raw["boxScore"])["players"]).map { |box| format_player_stats(box) },
      leaders: hashes(raw["leaders"]).map { |group| format_leaders(group) },
      scoring_plays: hashes(raw["scoringPlays"]).map { |play| format_scoring_play(play) },
      officials: hashes(info["officials"]).map do |official|
        { name: official["displayName"], position: object(official["position"])["displayName"] }
      end
    }
  end

  # --- parts -------------------------------------------------------------------

  def self.format_competitor(competitor)
    team = object(competitor["team"])
    {
      id: team["id"],
      name: team["displayName"],
      abbreviation: team["abbreviation"],
      home_away: competitor["homeAway"],
      logo: Array(team["logos"]).find { |logo| logo.is_a?(Hash) }&.dig("href"),
      score: integer(competitor["score"]),
      winner: competitor["winner"] == true,
      record: hashes(competitor["record"]).find { |r| r["type"] == "total" }&.dig("summary"),
      quarters: hashes(competitor["linescores"]).map { |line| integer(line["displayValue"]) } # [7, 0, 7, 0]
    }
  end

  # { team:, stats: [ { name: "totalYards", label: "Total Yards", value: "393" }, ... ] }
  # Values stay text on purpose ("27/37", "37:31"): that is how the API gives them.
  def self.format_team_stats(box)
    {
      team: team_ref(box["team"]),
      stats: hashes(box["statistics"]).map do |stat|
        { name: stat["name"], label: stat["label"], value: stat["displayValue"] }
      end
    }
  end

  # { team:, categories: [ { category: "passing", columns: [...], players: [...], totals: {...} } ] }
  # Each player's stats are lined up with the category's columns, like a table.
  def self.format_player_stats(box)
    {
      team: team_ref(box["team"]),
      categories: hashes(box["statistics"]).map do |category|
        keys = Array(category["keys"])
        {
          category: category["name"],
          columns: keys.zip(Array(category["labels"])).map { |key, label| { name: key, label: label } },
          players: hashes(category["athletes"]).map do |entry|
            athlete = object(entry["athlete"])
            { id: athlete["id"], name: athlete["displayName"], stats: keys.zip(Array(entry["stats"])).to_h }
          end,
          totals: Array(category["totals"]).any? ? keys.zip(Array(category["totals"])).to_h : nil
        }
      end
    }
  end

  # { team:, leaders: [ { category: "passingYards", label:, player: {...}, summary: "17/27, 209 YDS, 1 TD" } ] }
  def self.format_leaders(group)
    {
      team: team_ref(group["team"]),
      leaders: hashes(group["leaders"]).filter_map do |category|
        top = hashes(category["leaders"]).first
        next unless top

        athlete = object(top["athlete"])
        {
          category: category["name"],
          label: category["displayName"],
          player: { id: athlete["id"], name: athlete["displayName"],
                    position: object(athlete["position"])["abbreviation"] },
          summary: top["displayValue"]
        }
      end
    }
  end

  def self.format_scoring_play(play)
    {
      quarter: object(play["period"])["number"],
      clock: object(play["clock"])["displayValue"],
      team: object(play["team"])["abbreviation"],
      type: object(play["type"])["text"], # "Passing Touchdown", "Field Goal Good"...
      text: play["text"],                 # "Trey McBride 3 Yd pass from Jacoby Brissett (Chad Ryland Kick)"
      away_score: play["awayScore"],
      home_score: play["homeScore"]
    }
  end

  def self.team_ref(team)
    team = object(team)
    { id: team["id"], abbreviation: team["abbreviation"] }
  end

  # --- cache lifetime ----------------------------------------------------------
  # Final -> 30 days. On (or past kickoff but still "pre") -> 5 minutes. Not started ->
  # until kickoff, between 2 minutes and 8 hours. Anything else (unknown state) -> 8 hours.
  def self.fresh_for(summary, now = Time.current)
    return FINISHED_TTL if finished?(summary)

    state = summary.dig(:status, :state)
    kickoff = kickoff_time(summary[:date])
    return LIVE_TTL if state == "in"
    return UPCOMING_MAX_TTL unless state == "pre" && kickoff
    return LIVE_TTL if kickoff <= now && kickoff > now - LATE_PRE_LIMIT
    return UPCOMING_MAX_TTL if kickoff <= now

    (kickoff - now).to_f.clamp(UPCOMING_MIN_TTL.to_i, UPCOMING_MAX_TTL.to_i).round.seconds
  end

  def self.finished?(summary)
    summary.dig(:status, :state) == "post" && summary.dig(:status, :completed) == true
  end

  # "2026-09-13T20:25Z" (the API leaves out the seconds)
  def self.kickoff_time(date)
    Time.iso8601(date.to_s.sub(/(T\d{2}:\d{2})Z\z/, '\1:00Z'))
  rescue ArgumentError
    nil
  end

  # --- helpers -----------------------------------------------------------------

  # "14" -> 14, 14 -> 14, anything else -> nil
  def self.integer(value)
    return value.to_i if value.is_a?(Numeric)

    Integer(value.to_s, 10, exception: false)
  end

  # Only the entries that are objects, so nulls or stray text in a list are skipped.
  def self.hashes(list)
    Array(list).select { |entry| entry.is_a?(Hash) }
  end

  # The value if it is an object (Hash), otherwise an empty one, so a null or a stray
  # string where an object belongs reads as "missing" instead of crashing with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  private_class_method :spend_lookup!, :format_competitor, :format_team_stats, :format_player_stats,
                       :format_leaders, :format_scoring_play, :team_ref, :kickoff_time,
                       :integer, :hashes, :object
end
