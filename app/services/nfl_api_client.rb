require "net/http"
require "json"

# Talks to the RapidAPI NFL API. Its only job is to make the HTTP call
# and return the parsed JSON. It knows nothing about caching or our endpoint.
class NflApiClient
  # The ONE error type callers need to handle. Any problem talking to the
  # upstream API (network, timeout, bad status, bad JSON) is raised as this.
  class Error < StandardError; end

  # The upstream API says the thing we asked for does not exist (for example an unknown
  # player id). It IS an Error, so code that rescues Error still catches it, but callers
  # that care can rescue NotFound first and answer with a 404 instead of a 502.
  class NotFound < Error; end

  # We chose NOT to call the upstream API because today's budget of calls for this kind of
  # request is used up. It IS an Error, so a backup copy is still served when there is one;
  # without a backup the controller answers 503 (try again later), not 502.
  class BudgetExceeded < Error; end

  # Low-level failures that Net::HTTP / JSON can raise.
  NETWORK_ERRORS = [
    Timeout::Error,           # includes Net::OpenTimeout and Net::ReadTimeout
    SocketError,              # includes DNS failures (Socket::ResolutionError)
    SystemCallError,          # includes Errno::ECONNREFUSED, ECONNRESET, ...
    OpenSSL::SSL::SSLError,
    JSON::ParserError
  ].freeze

  # The API often reports "not found" as an HTTP 500 with one of these messages:
  #   unknown player id  -> {"error":"Request failed with status code 404"}
  #   unknown week/year  -> {"error":"Something wrong: Cannot read properties of undefined (reading 'schedule')"}
  NOT_FOUND_MESSAGES = [ "status code 404", "reading 'schedule'" ].freeze

  TEAM_LIST_PATH = "/nflteamlist".freeze
  NEWS_PATH = "/nfl-news".freeze
  INJURIES_PATH = "/v2/injuries".freeze
  TEAM_STATISTIC_PATH = "/nfl-team-statistic".freeze
  TEAM_PLAYERS_PATH = "/players/id".freeze
  TEAM_INFO_PATH = "/nflteaminfo".freeze
  TEAM_SCHEDULE_PATH = "/nfl-schedule-team".freeze
  GAME_SUMMARY_PATH = "/nflsummary".freeze
  PLAYER_OVERVIEW_PATH = "/player-overview".freeze
  SCHEDULE_PATH = "/nflschedule".freeze
  WEEKLY_SCHEDULE_PATH = "/nfl-schedule-weekly".freeze
  STANDINGS_PATH = "/nflstandings".freeze

  def team_list
    get(TEAM_LIST_PATH)
  end

  # The CURRENT week's games. The answer is grouped by date:
  # { "20261115" => { "games" => [ {game}, ... ] }, ... }. Anything else (or no days at
  # all) is a failure, so we never cache an empty schedule.
  def schedule
    ensure_schedule_shape(get(SCHEDULE_PATH))
  end

  # The games of ONE chosen week, in the same shape as `schedule`. With only a year the
  # API quietly returns Week 1, so always send both. Raises NotFound for a year or week
  # the API has no schedule for (it reports that as a 500, see not_found? below).
  def schedule_for(year, week)
    ensure_schedule_shape(get(WEEKLY_SCHEDULE_PATH, year: year, week: week))
  end

  # The league table of ONE season. The year is REQUIRED by the API (without it: HTTP 400
  # "Please provide the year"). For a year it does not have, the API quietly answers with
  # the CURRENT season instead, so callers must compare the season inside the answer with
  # the year they asked for (NflStandings does). An answer without teams is a failure.
  def standings(year)
    payload = get(STANDINGS_PATH, year: year)

    entries = payload.is_a?(Hash) ? payload.dig("standings", "entries") : nil
    entries_ok = entries.is_a?(Array) && entries.any? &&
                 entries.all? { |entry| entry.is_a?(Hash) && entry["team"].is_a?(Hash) && entry["stats"].is_a?(Array) }
    raise Error, "NFL API standings had an unexpected shape" unless entries_ok

    payload
  end

  def news
    get(NEWS_PATH)
  end

  # This endpoint wraps its data as { "status": "success", "data": [...], "error": null }.
  # A failure can arrive as HTTP 200 with "status": "error", so check it ourselves.
  def injuries
    payload = get(INJURIES_PATH)

    unless payload.is_a?(Hash) && payload["status"] == "success"
      detail = payload.is_a?(Hash) ? payload["error"].inspect : "unexpected response"
      raise Error, "NFL API injuries failed: #{detail}"
    end

    payload
  end

  # Statistics for ONE team. This API has no status field, so if the answer does not
  # contain the stats we expect, treat it as a failure instead of caching an empty
  # answer for 24 hours.
  def team_statistic(team_id)
    payload = get(TEAM_STATISTIC_PATH, teamId: team_id)

    categories = payload.dig("stats", "categories") if payload.is_a?(Hash)
    unless categories.is_a?(Array) && categories.any?
      raise Error, "NFL API team statistic had an unexpected shape"
    end

    payload
  end

  # The players of ONE team. The answer looks like { "data": [ {player}, ... ] }; anything
  # else is treated as a failure so we never cache an empty roster for 24 hours.
  def team_players(team_id)
    payload = get(TEAM_PLAYERS_PATH, teamId: team_id)

    # Every NFL team has players, so an empty list is a bad answer too.
    unless payload.is_a?(Hash) && payload["data"].is_a?(Array) && payload["data"].any?
      raise Error, "NFL API team players had an unexpected shape"
    end

    payload
  end

  # Details of ONE team: record, venue, next game... The answer looks like
  # { "team": { "id": "22", ... } }. Note the parameter is "teamid" here (all lower case),
  # not "teamId" as in the other team endpoints. Anything without a team is a failure.
  def team_info(team_id)
    payload = get(TEAM_INFO_PATH, teamid: team_id)

    team = payload["team"] if payload.is_a?(Hash)
    raise Error, "NFL API team info had an unexpected shape" unless team.is_a?(Hash) && team["id"].present?

    payload
  end

  # ONE team's games in ONE season (regular season only). The answer is wrapped as
  # { "status": "success", "season": {...}, "team": {...}, "events": [ {game}, ... ] }.
  # Every team plays every season, so a failed status, no team or no games is a failure.
  def team_schedule(team_id, season)
    payload = get(TEAM_SCHEDULE_PATH, season: season, teamId: team_id)

    shape_ok = payload.is_a?(Hash) && payload["status"] == "success" && payload["team"].is_a?(Hash) &&
               payload["events"].is_a?(Array) && payload["events"].any?
    raise Error, "NFL API team schedule had an unexpected shape" unless shape_ok

    payload
  end

  # Everything about ONE game: score by quarter, box score, leaders, scoring plays...
  # Raises NotFound for an unknown game id (HTTP 500 with "status code 404", like players).
  # An answer without a header (which says which game it is) is a failure.
  def game_summary(game_id)
    payload = get(GAME_SUMMARY_PATH, id: game_id)

    unless payload.is_a?(Hash) && payload["header"].is_a?(Hash)
      raise Error, "NFL API game summary had an unexpected shape"
    end

    payload
  end

  # Everything about ONE player. Raises NotFound for an unknown player id. The API reports
  # that oddly (HTTP 500 with a body saying "status code 404"); see not_found? below.
  def player_overview(player_id)
    payload = get(PLAYER_OVERVIEW_PATH, playerId: player_id)

    unless payload.is_a?(Hash) && payload["player_overview"].is_a?(Hash)
      raise Error, "NFL API player overview had an unexpected shape"
    end

    payload
  end

  private

  # params: query-string values, e.g. { teamId: 24 }. They are URL-encoded for us.
  def get(path, params = {})
    query = URI.encode_www_form(params) if params.any?
    uri = URI::HTTPS.build(host: host, path: path, query: query)

    request = Net::HTTP::Get.new(uri)
    request["x-rapidapi-key"] = api_key
    request["x-rapidapi-host"] = host

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                               open_timeout: 5, read_timeout: 15) do |http|
      http.request(request)
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise NotFound, "NFL API said not found (#{response.code})" if not_found?(response)

      raise Error, "NFL API returned #{response.code}"
    end

    JSON.parse(response.body)
  rescue *NETWORK_ERRORS => e
    raise Error, "#{e.class}: #{e.message}"
  end

  # Games grouped by date, at least one day, every day holding a list of games.
  # Anything else is a failure, so we never cache an empty or garbled schedule.
  def ensure_schedule_shape(payload)
    days_ok = payload.is_a?(Hash) && payload.any? &&
              payload.values.all? { |day| day.is_a?(Hash) && day["games"].is_a?(Array) }
    raise Error, "NFL API schedule had an unexpected shape" unless days_ok

    payload
  end

  # A real 404, or one of the API's messages that mean "not found" (see NOT_FOUND_MESSAGES).
  def not_found?(response)
    return true if response.code == "404"

    body = response.body.to_s
    NOT_FOUND_MESSAGES.any? { |message| body.include?(message) }
  end

  def api_key
    Rails.application.credentials.rapidapi.fetch(:key)
  end

  def host
    Rails.application.credentials.rapidapi.fetch(:host)
  end
end
