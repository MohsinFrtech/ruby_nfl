require "test_helper"
require "net/http" # the tests use Net::HTTP classes directly, so don't rely on autoload order

class NflApiClientTest < ActiveSupport::TestCase
  # A fake Net::HTTP connection: remembers the request it was given and
  # returns (or raises) whatever we tell it to.
  class FakeConnection
    attr_reader :request_received

    def initialize(outcome)
      @outcome = outcome
    end

    def request(req)
      @request_received = req
      raise @outcome if @outcome.is_a?(Exception)
      @outcome
    end
  end

  # Builds a real Net::HTTP response object without any network.
  # Setting @read/@body is the standard trick to give it a body.
  def build_response(klass, code, body = "")
    klass.new("1.1", code, "").tap do |response|
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)
    end
  end

  # Replaces Net::HTTP.start so no real request is made. The code under test
  # still runs its normal `Net::HTTP.start(...) { |http| http.request(...) }`.
  def with_fake_http(connection)
    fake_start = ->(*_args, **_options, &block) { block.call(connection) }
    Net::HTTP.stub(:start, fake_start) { yield }
  end

  test "team_list returns the parsed JSON on success" do
    body = file_fixture("nflteamlist.json").read
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.team_list }

    assert_equal JSON.parse(body), result
  end

  test "team_list sends the path and RapidAPI headers" do
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", "{}"))

    with_fake_http(connection) { NflApiClient.new.team_list }

    request = connection.request_received
    credentials = Rails.application.credentials.rapidapi
    assert_equal "/nflteamlist", request.path
    assert_equal credentials[:key], request["x-rapidapi-key"]
    assert_equal credentials[:host], request["x-rapidapi-host"]
  end

  test "news requests /nfl-news and returns the parsed JSON list" do
    body = file_fixture("nfl-news.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.news }

    assert_equal "/nfl-news", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "injuries requests /v2/injuries and returns the parsed JSON" do
    body = file_fixture("injuries.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.injuries }

    assert_equal "/v2/injuries", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "injuries raises NflApiClient::Error when a 200 response says status error" do
    body = { status: "error", data: nil, error: "rate limited upstream" }.to_json
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    error = assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.injuries }
    end
    assert_match "rate limited upstream", error.message
  end

  test "injuries raises NflApiClient::Error when the 200 body is not the expected object" do
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", "[]"))

    assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.injuries }
    end
  end

  test "team_statistic sends the team id as a query parameter and returns the parsed JSON" do
    body = file_fixture("team-statistic.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.team_statistic("24") }

    assert_equal "/nfl-team-statistic?teamId=24", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "team_statistic URL-encodes the team id so it cannot change the request" do
    body = file_fixture("team-statistic.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    with_fake_http(connection) { NflApiClient.new.team_statistic("1&admin=true") }

    assert_equal "/nfl-team-statistic?teamId=1%26admin%3Dtrue", connection.request_received.path
  end

  test "team_players requests /players/id with the team id and returns the parsed JSON" do
    body = file_fixture("team-players.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.team_players("29") }

    assert_equal "/players/id?teamId=29", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "team_info requests /nflteaminfo with a lower-case teamid and returns the parsed JSON" do
    body = file_fixture("team-info.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.team_info("22") }

    assert_equal "/nflteaminfo?teamid=22", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "team_info URL-encodes the team id so it cannot change the request" do
    body = file_fixture("team-info.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    with_fake_http(connection) { NflApiClient.new.team_info("1&admin=true") }

    assert_equal "/nflteaminfo?teamid=1%26admin%3Dtrue", connection.request_received.path
  end

  test "team_info raises NflApiClient::Error when the answer has no team" do
    [ "{}", "[]", '{"message":"x"}', '{"team":null}', '{"team":"junk"}', '{"team":{}}', '{"team":{"id":""}}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.team_info("22") }
      end
    end
  end

  test "team_schedule requests /nfl-schedule-team with the season and team id" do
    body = file_fixture("team-schedule.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.team_schedule("22", "2026") }

    assert_equal "/nfl-schedule-team?season=2026&teamId=22", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "team_schedule raises NflApiClient::Error when the answer has no team or no games" do
    [ "{}", "[]", '{"status":"error","error":"x"}', '{"status":"success","team":{},"events":[]}',
      '{"status":"success","team":"junk","events":[{}]}', '{"status":"success","team":{},"events":"junk"}',
      '{"team":{},"events":[{}]}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.team_schedule("22", "2026") }
      end
    end
  end

  test "game_summary requests /nflsummary with the game id and returns the parsed JSON" do
    body = file_fixture("game-summary.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.game_summary("401872926") }

    assert_equal "/nflsummary?id=401872926", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "game_summary raises NotFound for an unknown game (the API's 500 with 'status code 404')" do
    # The real answer for /nflsummary?id=999999999
    body = '{"error":"Something wrong: Request failed with status code 404","code":"ERR_BAD_REQUEST"}'
    connection = FakeConnection.new(build_response(Net::HTTPInternalServerError, "500", body))

    assert_raises(NflApiClient::NotFound) do
      with_fake_http(connection) { NflApiClient.new.game_summary("999999999") }
    end
  end

  test "game_summary raises NflApiClient::Error when the answer has no header" do
    [ "{}", "[]", '{"message":"x"}', '{"header":null}', '{"header":"junk"}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.game_summary("401872926") }
      end
    end
  end

  test "schedule requests /nflschedule with no query and returns the parsed JSON" do
    body = file_fixture("nflschedule.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.schedule }

    assert_equal "/nflschedule", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "schedule raises NflApiClient::Error when the answer is not games grouped by date" do
    [ "{}", "[]", '{"error":"x"}', '{"20261112":"oops"}', '{"20261112":{}}', '{"20261112":{"games":null}}',
      '{"20261112":{"games":[]},"20261115":"oops"}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.schedule }
      end
    end
  end

  test "schedule_for sends the year and the week and returns the parsed JSON" do
    body = file_fixture("nflschedule.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.schedule_for("2026", "10") }

    assert_equal "/nfl-schedule-weekly?year=2026&week=10", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "schedule_for URL-encodes the year and week so they cannot change the request" do
    body = file_fixture("nflschedule.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    with_fake_http(connection) { NflApiClient.new.schedule_for("2026&admin=true", "1;2") }

    assert_equal "/nfl-schedule-weekly?year=2026%26admin%3Dtrue&week=1%3B2", connection.request_received.path
  end

  test "schedule_for raises NflApiClient::Error when the answer is not games grouped by date" do
    [ "{}", "[]", '{"error":"x"}', '{"20261112":"oops"}', '{"20261112":{"games":null}}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.schedule_for("2026", "10") }
      end
    end
  end

  test "a week or year the API has no schedule for, reported as a 500, raises NotFound" do
    body = %({"error":"Something wrong: Cannot read properties of undefined (reading 'schedule')"})
    connection = FakeConnection.new(build_response(Net::HTTPInternalServerError, "500", body))

    assert_raises(NflApiClient::NotFound) do
      with_fake_http(connection) { NflApiClient.new.schedule_for("2026", "19") }
    end
  end

  test "an unrelated 500 on the schedule is a plain Error and not NotFound" do
    connection = FakeConnection.new(build_response(Net::HTTPInternalServerError, "500", '{"error":"boom"}'))

    error = assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.schedule_for("2026", "10") }
    end
    assert_instance_of NflApiClient::Error, error
  end

  test "standings sends the year and returns the parsed JSON" do
    body = file_fixture("standings.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.standings("2026") }

    assert_equal "/nflstandings?year=2026", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "standings URL-encodes the year so it cannot change the request" do
    body = file_fixture("standings.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    with_fake_http(connection) { NflApiClient.new.standings("2026&admin=true") }

    assert_equal "/nflstandings?year=2026%26admin%3Dtrue", connection.request_received.path
  end

  test "standings raises NflApiClient::Error when the answer has no teams in the expected shape" do
    [ "{}", "[]", '{"message":"Please provide the year"}', '{"standings":null}', '{"standings":{"entries":[]}}',
      '{"standings":{"entries":["x"]}}', '{"standings":{"entries":[{"team":{}}]}}',
      '{"standings":{"entries":[{"stats":[]}]}}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.standings("2026") }
      end
    end
  end

  test "standings: HTTP 400 (no year) is a plain Error and not NotFound" do
    connection = FakeConnection.new(build_response(Net::HTTPBadRequest, "400", '{"message":"Please provide the year"}'))

    error = assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.standings("") }
    end
    assert_instance_of NflApiClient::Error, error
  end

  test "player_overview sends the player id and returns the parsed JSON" do
    body = file_fixture("player-overview.json").binread
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

    result = with_fake_http(connection) { NflApiClient.new.player_overview("4685720") }

    assert_equal "/player-overview?playerId=4685720", connection.request_received.path
    assert_equal JSON.parse(body), result
  end

  test "player_overview raises NflApiClient::Error when the answer is not an overview" do
    [ '{"message":"oops"}', "[]", '{"player_overview":null}', '{"player_overview":[]}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.player_overview("4685720") }
      end
    end
  end

  test "an unknown id, which the API reports as a 500 about a 404, raises NotFound" do
    body = '{"error":"Request failed with status code 404"}'
    connection = FakeConnection.new(build_response(Net::HTTPInternalServerError, "500", body))

    assert_raises(NflApiClient::NotFound) do
      with_fake_http(connection) { NflApiClient.new.player_overview("999999999") }
    end
  end

  test "a real 404 also raises NotFound" do
    connection = FakeConnection.new(build_response(Net::HTTPNotFound, "404", "{}"))

    assert_raises(NflApiClient::NotFound) do
      with_fake_http(connection) { NflApiClient.new.player_overview("999999999") }
    end
  end

  test "any other failure is a plain Error and not NotFound" do
    connection = FakeConnection.new(build_response(Net::HTTPInternalServerError, "500", '{"error":"boom"}'))

    error = assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.player_overview("4685720") }
    end
    assert_instance_of NflApiClient::Error, error
  end

  test "NotFound is a kind of Error, so code that rescues Error still catches it" do
    assert_operator NflApiClient::NotFound, :<, NflApiClient::Error
  end

  test "team_players raises NflApiClient::Error when the answer has no player list" do
    [ '{"message":"Team not found"}', "[]", '{"data":null}', '{"data":"x"}', '{"data":[]}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.team_players("29") }
      end
    end
  end

  test "team_statistic raises NflApiClient::Error when the answer has no stats" do
    [ '{"message":"Team not found"}', "[]", '{"stats":{}}', '{"stats":{"categories":[]}}' ].each do |body|
      connection = FakeConnection.new(build_response(Net::HTTPOK, "200", body))

      assert_raises(NflApiClient::Error, "expected #{body} to be rejected") do
        with_fake_http(connection) { NflApiClient.new.team_statistic("24") }
      end
    end
  end

  test "team_list raises NflApiClient::Error on a non-2xx response" do
    connection = FakeConnection.new(build_response(Net::HTTPForbidden, "403", "{}"))

    error = assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.team_list }
    end
    assert_match "403", error.message
  end

  test "team_list raises NflApiClient::Error on a timeout" do
    connection = FakeConnection.new(Net::ReadTimeout.new("took too long"))

    assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.team_list }
    end
  end

  test "team_list raises NflApiClient::Error when the connection is refused" do
    connection = FakeConnection.new(Errno::ECONNREFUSED.new)

    assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.team_list }
    end
  end

  test "team_list raises NflApiClient::Error when the body is not valid JSON" do
    connection = FakeConnection.new(build_response(Net::HTTPOK, "200", "<html>oops</html>"))

    assert_raises(NflApiClient::Error) do
      with_fake_http(connection) { NflApiClient.new.team_list }
    end
  end
end
