# Everything about ONE player, cleaned up and cached per player.
#
# The raw answer is 125-260 KB and changes shape from player to player: a
# rookie on injured reserve has no statistics, a veteran may have awards, some
# players have no fantasy section. So every section is optional, and a section
# the API did not give us is simply left out of our answer.
class NflPlayerOverview
  # The player id is not a known NFL player.
  class UnknownPlayer < StandardError; end

  CACHE_TTL = 24.hours # stats change weekly, news and fantasy numbers daily
  STALE_GRACE = 3.days # if the API is down, serve the old overview up to 3 days past expiry
  MISSING_TTL = 1.hour # remember "this id does not exist" so a fake id is not retried constantly

  # At most this many RapidAPI calls a day (UTC) for player overviews, about 7,500 a month.
  # Together with game summaries (150 a day, about 4,500) that is 12,000 of the 20,000 monthly
  # quota at most, leaving room for every other endpoint.
  # Any id that LOOKS valid costs a call, even a made-up one, so without a budget one script
  # could use up the whole monthly quota in hours. Over the budget, players already in the
  # cache (or their backups) are still served; only new lookups wait until tomorrow.
  # (The count lives in Rails.cache, so it starts again from 0 after a dyno restart.)
  DAILY_LOOKUPS = 250

  # Real ids are plain positive numbers (we have seen 1 and 7-digit ids). "007", "1e3",
  # " 1", "-5" and "abc" are refused, and refusing leading zeros means one player can
  # never end up with two different cache entries.
  ID_FORMAT = /\A[1-9]\d{0,9}\z/

  def self.cache_key(player_id)
    "nfl/player_overview/v1/#{player_id}"
  end

  def self.missing_key(player_id)
    "nfl/player_overview/missing/v1/#{player_id}"
  end

  # The method our controller will call.
  #
  # A badly formed id is refused without any call. An id the API says does not
  # exist is remembered for an hour. Neither creates a normal cache entry.
  def self.for(player_id)
    id = player_id.to_s
    raise UnknownPlayer, "bad player id #{id.inspect}" unless id.match?(ID_FORMAT)
    raise UnknownPlayer, "no player with id #{id}" if Rails.cache.exist?(missing_key(id))

    StaleCache.fetch(cache_key(id), expires_in: CACHE_TTL, grace: STALE_GRACE) do
      spend_lookup! # only reached when RapidAPI is really about to be called

      { fetched_at: Time.current.utc.iso8601, player_id: id }
        .merge(from_api(NflApiClient.new.player_overview(id)))
    end
  rescue NflApiClient::NotFound
    Rails.cache.write(missing_key(id), true, expires_in: MISSING_TTL)
    raise UnknownPlayer, "no player with id #{id}"
  end

  def self.budget_key(date = Time.current.utc.to_date)
    "nfl/player_overview/budget/v1/#{date.iso8601}"
  end

  # Counts one RapidAPI call against today's budget, or refuses it if the budget is used up.
  def self.spend_lookup!
    used = Rails.cache.increment(budget_key, 1, expires_in: 2.days)
    return if used.nil? || used <= DAILY_LOOKUPS # nil: the cache could not count; do not block

    raise NflApiClient::BudgetExceeded, "player lookup budget of #{DAILY_LOOKUPS} a day is used up"
  end

  # raw: the parsed JSON Hash from NflApiClient#player_overview
  # returns: a Hash that contains only the sections that have something in them
  def self.from_api(raw)
    overview = raw.is_a?(Hash) ? raw["player_overview"] : nil
    return {} unless overview.is_a?(Hash)

    {
      statistics: format_statistics(overview["statistics"]),
      game_log: format_game_log(overview["gameLog"]),
      next_game: format_next_game(overview["nextGame"]),
      news: NflNews.from_api(overview["news"]), # same clean shape as GET /news
      fantasy: format_fantasy(overview["fantasy"]),
      rotowire: format_rotowire(overview["rotowire"]),
      awards: format_awards(overview["awards"])
    }.reject { |_section, value| value.blank? }
  end

  # --- statistics ----------------------------------------------------------
  # The API sends a TABLE: a list of column names, then rows of values lined up
  # with them. We keep the columns once, and turn each row into name => value.
  # Values stay text on purpose ("2,197"): that is how the API gives them.
  def self.format_statistics(stats)
    names = stats.is_a?(Hash) ? Array(stats["names"]) : []
    return nil if names.empty?

    labels = Array(stats["labels"])
    titles = Array(stats["displayNames"])
    groups = column_groups(stats["categories"])

    {
      title: stats["displayName"],
      columns: names.each_with_index.map do |name, i|
        { name: name, label: labels[i], title: titles[i], category: groups[i] }
      end,
      splits: Array(stats["splits"]).select { |split| split.is_a?(Hash) }.map do |split|
        { split: split["displayName"], stats: names.zip(Array(split["stats"])).to_h }
      end
    }
  end

  # categories like [{name: "passing", count: 10}, {name: "rushing", count: 5}]
  # become one group name per column: ["passing" x10, "rushing" x5]
  def self.column_groups(categories)
    Array(categories).flat_map { |category| [ object(category)["name"] ] * object(category)["count"].to_i.clamp(0, 1000) }
  end

  # --- game log ------------------------------------------------------------
  # Game details are stored once by game id; the stats tables refer to them by id.
  def self.format_game_log(log)
    return nil unless log.is_a?(Hash) && log["events"].is_a?(Hash)

    tables = Array(log["statistics"]).select { |table| table.is_a?(Hash) }

    log["events"].filter_map do |event_id, event|
      next unless event.is_a?(Hash)

      opponent = object(event["opponent"])
      {
        id: event["id"] || event_id,
        week: event["week"],
        date: event["gameDate"],
        home_away: event["atVs"], # "vs" = home, "@" = away
        opponent: opponent["displayName"],
        opponent_abbreviation: opponent["abbreviation"],
        result: event["gameResult"],
        score: event["score"],
        home_team_id: event["homeTeamId"],
        away_team_id: event["awayTeamId"],
        home_score: event["homeTeamScore"],
        away_score: event["awayTeamScore"],
        stats: game_stats(tables, event_id)
      }
    end.sort_by { |game| game[:date].to_s }.reverse
  end

  # { "passing" => { "completions" => "28", ... }, "rushing" => { ... } }
  def self.game_stats(tables, event_id)
    tables.filter_map do |table|
      row = Array(table["events"]).find { |event| object(event)["eventId"] == event_id }
      next unless row

      [ table["displayName"].to_s.downcase, Array(table["names"]).zip(Array(row["stats"])).to_h ]
    end.to_h
  end

  # --- next game -----------------------------------------------------------
  def self.format_next_game(next_game)
    events = object(object(next_game)["league"])["events"]
    event = events.is_a?(Array) ? events.first : nil
    return nil unless event.is_a?(Hash)

    {
      id: event["id"],
      name: event["name"],
      short_name: event["shortName"],
      date: event["date"],
      week: event["week"],
      status: event["status"], # "pre" = not started yet
      venue: event["location"],
      broadcast: event["broadcast"].presence,
      teams: Array(event["competitors"]).select { |team| team.is_a?(Hash) }.map do |team|
        { id: team["id"], name: team["displayName"], abbreviation: team["abbreviation"],
          home_away: team["homeAway"] }
      end,
      odds: format_odds(event["odds"])
    }
  end

  def self.format_odds(odds)
    return nil unless odds.is_a?(Hash)

    { details: odds["details"], over_under: odds["overUnder"], spread: odds["spread"] }
      .compact.presence
  end

  # --- fantasy, rotowire, awards ------------------------------------------
  # The API sends these numbers as text ("80.58"); turn them into real numbers.
  def self.format_fantasy(fantasy)
    return nil unless fantasy.is_a?(Hash) && fantasy.any?

    {
      draft_rank: to_number(fantasy["draftRank"]),
      position_rank: to_number(fantasy["positionRank"]),
      percent_owned: to_number(fantasy["percentOwned"]),
      last_7_days: to_number(fantasy["last7Days"]),
      projection: fantasy["projection"].presence
    }
  end

  # `published` stays exactly as the API writes it ("Sun Nov 08 16:07:48 PST 2026"):
  # time zone abbreviations cannot be parsed reliably, so we do not guess.
  def self.format_rotowire(rotowire)
    return nil unless rotowire.is_a?(Hash) && rotowire.any?

    { headline: rotowire["headline"], story: rotowire["story"], published: rotowire["published"] }
  end

  def self.format_awards(awards)
    Array(awards).select { |award| award.is_a?(Hash) }.map do |award|
      { name: award["name"], count: award["displayCount"], seasons: Array(award["seasons"]) }
    end
  end

  # "1430" -> 1430, "80.58" -> 80.58, "010" -> 10 (base 10, not octal), "n/a" -> nil
  def self.to_number(value)
    return value if value.is_a?(Numeric)

    Integer(value.to_s, 10, exception: false) || Float(value.to_s, exception: false)
  end

  # The value if it is an object (Hash), otherwise an empty one, so a null or a stray
  # string where an object belongs reads as "missing" instead of crashing with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  private_class_method :format_statistics, :column_groups, :format_game_log, :game_stats,
                       :format_next_game, :format_odds, :format_fantasy, :format_rotowire,
                       :format_awards, :to_number, :object, :spend_lookup!
end
