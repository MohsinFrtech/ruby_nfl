# The schedule of an NFL week: who plays whom, when, where, on which channel, and
# the score (live or final). Cleaned up, flattened into one list of games sorted by
# kickoff, and cached for a time that depends on the games.
#
#   NflSchedule.current          the week the API considers current
#   NflSchedule.for(2026, 10)    one chosen week
class NflSchedule
  # The requested year or week is not one we can have a schedule for.
  class UnknownSchedule < StandardError; end

  CACHE_KEY = "nfl/schedule/current/v1".freeze

  # How long a fetched schedule stays fresh depends on what is in it:
  LIVE_TTL = 2.minutes # a game is on (or should have started): scores are moving

  # Nothing live: kickoff times can change, and the API moves on to the next week at
  # some point, so look again within the hour.
  UPCOMING_MAX_TTL = 1.hour

  UPCOMING_MIN_TTL = 1.minute # never refresh more often than this just because a kickoff is near

  # A game still marked "pre" after its kickoff counts as live (the API can be late to
  # flip it), but only this long. A game stuck on "pre" for good (a data mistake) must not
  # keep the schedule on the 2-minute refresh until the week changes.
  LATE_PRE_LIMIT = 6.hours

  # If the API is down, how long past expiry a backup may still be shown.
  FINISHED_GRACE = 1.day      # a finished week does not change; an old copy is still right
  UNFINISHED_GRACE = 3.hours  # an old "Scheduled" for a game that has since been played would mislead

  # For a CHOSEN week the rules for a finished week are different. "Week 10 of 2026"
  # never changes meaning, so once every game is over it can be kept for a long time.
  # (The current week cannot: the API moves on to the next week and we must notice.)
  CHOSEN_FINISHED_TTL = 7.days
  CHOSEN_FINISHED_GRACE = 30.days

  # A chosen week whose next kickoff is more than FAR_KICKOFF away barely changes, so it is
  # kept up to CHOSEN_FAR_TTL instead of 1 hour, but never past "one day before kickoff".
  # From then on the normal rules apply (hourly, at kickoff, every 2 minutes while live).
  # Without this, someone checking every future week each hour could use up the quota.
  FAR_KICKOFF = 1.day
  CHOSEN_FAR_TTL = 12.hours
  MISSING_TTL = 1.hour # remember "no such week" so a made-up request is not retried constantly
  WEEKS = (1..18) # regular season (the API also reports 2020 and earlier as having 17)
  FIRST_YEAR = 2000

  # The method our controller will call for GET /schedule.
  def self.current
    StaleCache.fetch(
      CACHE_KEY,
      expires_in: ->(data) { fresh_for(data[:games]) },
      grace: ->(data) { grace_for(data[:games]) }
    ) do
      schedule = from_api(NflApiClient.new.schedule)
      # An empty week must never be cached: it would look the same as "nothing to do".
      raise NflApiClient::Error, "NFL API schedule had no games" if schedule[:games].empty?

      { fetched_at: Time.current.utc.iso8601 }.merge(schedule)
    end
  end

  # The method our controller will call for GET /schedule/:year/:week.
  #
  # The year and week are checked FIRST. A silly request (week 99, year 1850, "abc") is
  # refused without calling RapidAPI and without creating a cache entry. A week the API
  # says it has no schedule for is remembered for an hour.
  def self.for(year, week)
    year = year.to_s
    week = week.to_s
    raise UnknownSchedule, "bad year or week: #{year.inspect}, #{week.inspect}" unless valid_year?(year) && valid_week?(week)
    raise UnknownSchedule, "no schedule for #{year} week #{week}" if Rails.cache.exist?(missing_key(year, week))

    StaleCache.fetch(
      week_key(year, week),
      expires_in: ->(data) { fresh_for(data[:games], Time.current, finished_ttl: CHOSEN_FINISHED_TTL, far_ttl: CHOSEN_FAR_TTL) },
      grace: ->(data) { grace_for(data[:games], finished_grace: CHOSEN_FINISHED_GRACE) }
    ) do
      schedule = from_api(NflApiClient.new.schedule_for(year, week))
      ensure_requested_week(schedule, year, week)

      { fetched_at: Time.current.utc.iso8601 }.merge(schedule)
    end
  rescue NflApiClient::NotFound
    Rails.cache.write(missing_key(year, week), true, expires_in: MISSING_TTL)
    raise UnknownSchedule, "no schedule for #{year} week #{week}"
  end

  def self.week_key(year, week)
    "nfl/schedule/week/v1/#{year}/#{week}"
  end

  def self.missing_key(year, week)
    "nfl/schedule/missing/v1/#{year}/#{week}"
  end

  # How long this list of (cleaned) games may be served from the cache.
  #
  #   a game is live, or its kickoff time has passed  -> 2 minutes
  #   every game is over AND finished_ttl was given   -> finished_ttl (chosen weeks only)
  #   next kickoff over a day away AND far_ttl given  -> up to far_ttl, until a day before kickoff
  #   otherwise: until the next kickoff, but between 1 minute and 1 hour
  #   (a finished week with no finished_ttl has no next kickoff, so it gets the full hour)
  def self.fresh_for(games, now = Time.current, finished_ttl: nil, far_ttl: nil)
    return LIVE_TTL if games.any? { |game| live?(game, now) }
    return finished_ttl if finished_ttl && all_finished?(games)

    next_kickoff = games.filter_map { |game| upcoming_kickoff(game, now) }.min
    return UPCOMING_MAX_TTL if next_kickoff.nil?

    until_kickoff = (next_kickoff - now).to_f
    if far_ttl && until_kickoff > FAR_KICKOFF.to_i
      return (until_kickoff - FAR_KICKOFF.to_i).clamp(UPCOMING_MAX_TTL.to_i, far_ttl.to_i).round.seconds
    end

    until_kickoff.clamp(UPCOMING_MIN_TTL.to_i, UPCOMING_MAX_TTL.to_i).round.seconds
  end

  def self.grace_for(games, finished_grace: FINISHED_GRACE)
    all_finished?(games) ? finished_grace : UNFINISHED_GRACE
  end

  # raw: the parsed JSON Hash from NflApiClient#schedule (games grouped by date)
  # returns: { year:, season_type:, week:, games: [...] } with games sorted by kickoff
  def self.from_api(raw)
    days = raw.is_a?(Hash) ? raw : {}

    entries = days.flat_map do |day_key, day|
      games = day.is_a?(Hash) ? Array(day["games"]) : []
      games.select { |game| game.is_a?(Hash) }.map { |game| [ day_key, game ] }
    end
    first = entries.first&.last || {}

    {
      year: object(first["season"])["year"],
      season_type: object(first["season"])["slug"], # "regular-season"
      week: object(first["week"])["number"],
      games: entries.map { |day_key, game| format_game(game, day_key) }
                    .sort_by { |game| [ game[:date].to_s, game[:id].to_s ] }
    }
  end

  def self.format_game(game, day_key)
    competition = object(Array(game["competitions"]).first)
    competitors = Array(competition["competitors"])
    status = object(object(game["status"])["type"])
    state = status["state"] # "pre" = not started, "in" = live, "post" = over
    completed = status["completed"] == true

    {
      id: game["id"],
      name: game["name"],
      short_name: game["shortName"],
      date: iso_time(game["date"]), # exact kickoff, UTC
      day: format_day(day_key),     # the US calendar day the game belongs to
      status: { state: state, description: status["description"], detail: status["detail"], completed: completed },
      venue: format_venue(competition["venue"]),
      neutral_site: competition["neutralSite"],
      note: object(Array(competition["notes"]).first)["headline"], # e.g. "NFL Munich Game"
      broadcast: competition["broadcast"].presence,
      attendance: competition["attendance"].to_i.positive? ? competition["attendance"] : nil,
      home: format_team(competitors.find { |c| object(c)["homeAway"] == "home" }, state, completed),
      away: format_team(competitors.find { |c| object(c)["homeAway"] == "away" }, state, completed),
      recap: object(Array(competition["headlines"]).find { |h| object(h)["type"] == "Recap" })["description"],
      url: object(Array(game["links"]).find { |link| Array(object(link)["rel"]).include?("summary") })["href"]
    }
  end

  # The API says "0" for the score of a game that has not started, and has no winner
  # until it is over. We show nil for both, so "0" always means a real zero.
  def self.format_team(competitor, state, completed)
    return nil unless competitor.is_a?(Hash)

    team = object(competitor["team"])
    {
      id: team["id"] || competitor["id"],
      name: team["displayName"],
      abbreviation: team["abbreviation"],
      logo: team["logo"],
      score: state == "pre" ? nil : Integer(competitor["score"].to_s, 10, exception: false),
      winner: completed ? competitor["winner"] : nil,
      record: object(Array(competitor["records"]).find { |r| object(r)["type"] == "total" })["summary"]
    }
  end

  def self.format_venue(venue)
    return nil unless venue.is_a?(Hash)

    {
      name: venue["fullName"],
      city: object(venue["address"])["city"],
      state: object(venue["address"])["state"],
      country: object(venue["address"])["country"],
      indoor: venue["indoor"]
    }
  end

  # "20261112" -> "2026-11-12"
  def self.format_day(day_key)
    key = day_key.to_s
    key.match?(/\A\d{8}\z/) ? "#{key[0, 4]}-#{key[4, 2]}-#{key[6, 2]}" : key
  end

  # "2026-11-15T14:30Z" -> "2026-11-15T14:30:00Z" (same format as fetched_at)
  def self.iso_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)&.utc&.iso8601 || value
  rescue ArgumentError
    value
  end

  # The value if it is an object (Hash), otherwise an empty one. Every read of the API's
  # data goes through this, so a null or a stray string where an object belongs is
  # treated as "missing" instead of crashing the whole schedule with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  # --- checks for a chosen week --------------------------------------------

  # 2000 up to NEXT year (next season's schedule is published in spring). No leading
  # zeros and no spaces, so one year can never end up with two cache entries.
  def self.valid_year?(year)
    year.match?(/\A20\d{2}\z/) && year.to_i.between?(FIRST_YEAR, Time.current.year + 1)
  end

  def self.valid_week?(week)
    week.match?(/\A[1-9]\d?\z/) && WEEKS.cover?(week.to_i)
  end

  # If the API answers with a different week than we asked for (it quietly returns Week 1
  # when it ignores a parameter), caching that under this week's key would show the wrong
  # games for days. Treat it as a failure instead. An empty week is refused too.
  def self.ensure_requested_week(schedule, year, week)
    raise NflApiClient::Error, "NFL API schedule had no games" if schedule[:games].empty?

    return if schedule[:year] == year.to_i && schedule[:week] == week.to_i

    raise NflApiClient::Error,
          "NFL API sent week #{schedule[:week].inspect} of #{schedule[:year].inspect}, expected #{week} of #{year}"
  end

  # --- the cache rule's helpers --------------------------------------------

  # At least one game, and every game is over.
  def self.all_finished?(games)
    games.any? && games.all? { |game| game.dig(:status, :completed) == true }
  end

  def self.kickoff(game)
    Time.zone.parse(game[:date].to_s) if game[:date].present?
  rescue ArgumentError
    nil
  end

  # Live, or "pre" although the kickoff time has already passed (the API can be a
  # little late to flip a game to live, so treat it as live).
  def self.live?(game, now)
    state = game.dig(:status, :state)
    return true if state == "in"

    kickoff_time = kickoff(game)
    state == "pre" && !kickoff_time.nil? && kickoff_time <= now && kickoff_time > now - LATE_PRE_LIMIT
  end

  # The kickoff of a game that has not started yet. Games that were postponed or
  # cancelled (not "pre", not live, not completed) are ignored: their old kickoff
  # time is in the past and must not make us refresh every minute.
  def self.upcoming_kickoff(game, now)
    return nil unless game.dig(:status, :state) == "pre"

    kickoff_time = kickoff(game)
    kickoff_time if kickoff_time && kickoff_time > now
  end

  private_class_method :format_game, :format_team, :format_venue, :format_day, :iso_time,
                       :kickoff, :live?, :upcoming_kickoff, :all_finished?, :valid_year?,
                       :valid_week?, :ensure_requested_week, :object
end
