require "test_helper"

class TeamStatisticsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @raw = JSON.parse(file_fixture("team-statistic.json").binread)
    @teams = NflTeams.from_api(JSON.parse(file_fixture("nflteamlist.json").binread))
    @team = @teams.first
  end

  def with_world(client)
    with_memory_cache do
      NflTeams.stub(:all, @teams) do
        NflApiClient.stub(:new, client) { yield }
      end
    end
  end

  test "GET /teams/:id/statistics returns the team and its stats as JSON" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/#{@team[:id]}/statistics" }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[fetched_at opponent_stats team team_stats], body.keys.sort
    assert_equal @team[:name], body["team"]["name"]
    assert_equal "passing", body["team_stats"].first["category"]
    assert_equal [ @team[:id] ], client.team_ids
  end

  test "GET /teams/:id/statistics returns 404 for an unknown team and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/99999/statistics" }

    assert_response :not_found
    assert_equal({ "error" => "Team not found" }, response.parsed_body)
    assert_equal 0, client.calls
  end

  test "GET /teams/:id/statistics returns 404 when the id is not a number" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/abc/statistics" }

    assert_response :not_found
    assert_equal 0, client.calls
  end

  test "GET /teams/:id/statistics returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/teams/#{@team[:id]}/statistics" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
