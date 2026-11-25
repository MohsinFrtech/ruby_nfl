# The league table of one NFL season, cleaned up and grouped into divisions.
#
#   NflStandings.for(2026)   one chosen season
#   NflStandings.current     the season the schedule says is current
#
# Everything is cached for 8 hours (a table only changes when a game finishes).
class NflStandings
  # The year is not one we can have standings for.
  class UnknownStandings < StandardError; end

  CACHE_TTL = 8.hours
  STALE_GRACE = 3.days # if the API is down, serve the old table up to 3 days past expiry
  MISSING_TTL = 1.hour # remember "no such season" so a made-up year is not retried constantly

  # The API's own list of seasons starts at 2002 (the year the league settled into today's
  # 8 divisions). Other years return a different kind of table, or someone else's data.
  FIRST_YEAR = 2002

  # The API gives only a division NUMBER. These names are OUR table, not RapidAPI's. Each id
  # was checked against the real data (2020 and 2026): its four teams are exactly that
  # division, and the ids are the same in both seasons.
  DIVISIONS = {
    4 => { name: "AFC East", conference: "AFC" },
    12 => { name: "AFC North", conference: "AFC" },
    13 => { name: "AFC South", conference: "AFC" },
    6 => { name: "AFC West", conference: "AFC" },
    1 => { name: "NFC East", conference: "NFC" },
    10 => { name: "NFC North", conference: "NFC" },
    11 => { name: "NFC South", conference: "NFC" },
    3 => { name: "NFC West", conference: "NFC" }
  }.freeze

  def self.cache_key(year)
    "nfl/standings/v1/#{year}"
  end

  def self.missing_key(year)
    "nfl/standings/missing/v1/#{year}"
  end

  # The method our controller calls for GET /standings/:year.
  #
  # The year is checked FIRST: a silly year is refused without calling RapidAPI and without
  # creating a cache entry. And the season INSIDE the answer must be the one we asked for:
  # for a year it does not have, the API quietly sends the current season, and caching that
  # under another year's key would show the wrong table for days.
  def self.for(year)
    year = year.to_s
    raise UnknownStandings, "bad year #{year.inspect}" unless valid_year?(year)
    raise UnknownStandings, "no standings for #{year}" if Rails.cache.exist?(missing_key(year))

    StaleCache.fetch(cache_key(year), expires_in: CACHE_TTL, grace: STALE_GRACE) do
      standings = from_api(NflApiClient.new.standings(year))
      ensure_requested_season(standings, year)

      { fetched_at: Time.current.utc.iso8601 }.merge(standings)
    end
  rescue NflApiClient::NotFound
    Rails.cache.write(missing_key(year), true, expires_in: MISSING_TTL)
    raise UnknownStandings, "no standings for #{year}"
  end

  # The method our controller calls for GET /standings. "Current" is whatever season the
  # schedule says it is (the schedule is cached, so this is normally free).
  def self.current
    season = NflSchedule.current[:year]
    raise NflApiClient::Error, "could not tell which season is current" if season.nil?

    self.for(season)
  end

  # raw: the parsed JSON Hash from NflApiClient#standings
  # returns: { year:, divisions: [ { id:, name:, conference:, teams: [...] } ] }
  def self.from_api(raw)
    standings = raw.is_a?(Hash) ? raw["standings"] : nil
    standings = {} unless standings.is_a?(Hash)

    teams = Array(standings["entries"]).select { |entry| entry.is_a?(Hash) }.map { |entry| format_team(entry) }

    {
      year: Integer(standings["season"].to_s, 10, exception: false),
      divisions: group_into_divisions(teams)
    }
  end

  # One team's row. The API lists many stats, and some by name TWICE (wins, losses, ... with
  # the same numbers, only floating-point rounding differs), so we take the first of each
  # name. Everything else (projected*, opponents lists, tie-break notes...) is left out.
  def self.format_team(entry)
    # (not index_by: that would keep the LAST copy of a repeated name, we want the first)
    stats = Array(entry["stats"]).select { |stat| stat.is_a?(Hash) }
                                 .each_with_object({}) { |stat, by_name| by_name[stat["name"]] ||= stat }
    team = entry["team"] || {}
    value = ->(name) { stats.dig(name, "value") }
    text = ->(name) { stats.dig(name, "displayValue").presence }

    {
      team: {
        id: team["id"],
        name: team["displayName"],
        abbreviation: team["abbreviation"],
        logo: Array(team["logos"]).find { |logo| Array(logo["rel"]).include?("default") }&.dig("href")
      },
      division_id: value.call("divisionId")&.to_i,
      division_rank: value.call("divisionRank")&.to_i,
      conference_rank: value.call("conferenceRank")&.to_i,
      record: text.call("overall"), # "5-3-1"
      wins: value.call("wins"),
      losses: value.call("losses"),
      ties: value.call("ties"),
      win_percent: value.call("winPercent")&.round(4),
      points_for: value.call("pointsScored"),
      points_against: value.call("pointsAllowed"),
      point_differential: value.call("pointDifferential"),
      division_record: text.call("divisionRecord"),
      conference_record: text.call("conferenceRecord"),
      games_behind: value.call("gamesBehind"), # the API's number; 0 for the team at the top
      strength_of_schedule: value.call("strengthOfSchedule")&.round(4),
      strength_of_victory: value.call("strengthOfVictory")&.round(4)
    }
  end

  # The API sends the teams alphabetically, with only a division number. Group them by
  # that number, name the divisions from our table, and put each division's teams in order.
  def self.group_into_divisions(teams)
    groups = teams.group_by { |team| team[:division_id] }.map do |id, members|
      info = DIVISIONS[id] || {}
      {
        id: id,
        name: info[:name],
        conference: info[:conference],
        teams: members.sort_by { |t| [ t[:division_rank] || 99, t.dig(:team, :name).to_s ] }
                       .map { |t| t.except(:division_id) }
      }
    end

    groups.sort_by { |g| [ g[:name].nil? ? 1 : 0, g[:conference].to_s, g[:name].to_s ] }
  end

  # --- checks ----------------------------------------------------------------

  def self.valid_year?(year)
    year.match?(/\A20\d{2}\z/) && year.to_i.between?(FIRST_YEAR, Time.current.year)
  end

  # No teams at all, or a season other than the one we asked for, means the API does not
  # have this year. Raised as NotFound so the caller answers 404 and remembers it.
  def self.ensure_requested_season(standings, year)
    raise NflApiClient::Error, "NFL API standings had no teams" if standings[:divisions].empty?
    return if standings[:year] == year.to_i

    raise NflApiClient::NotFound,
          "NFL API sent season #{standings[:year].inspect}, expected #{year}"
  end

  private_class_method :format_team, :group_into_divisions, :valid_year?, :ensure_requested_season
end
