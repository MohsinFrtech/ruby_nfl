require "test_helper"

class TeamScheduleControllerTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 11, 25, 9)

  setup do
    @raw = JSON.parse(file_fixture("team-schedule.json").binread)
    @teams = NflTeams.from_api(JSON.parse(file_fixture("nflteamlist.json").binread))
  end

  def with_world(client)
    travel_to(NOW) do
      with_memory_cache do
        NflTeams.stub(:all, @teams) do
          NflApiClient.stub(:new, client) { yield }
        end
      end
    end
  end

  test "GET /teams/:id/schedule returns the current season's games as JSON" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/22/schedule" }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[bye_week fetched_at games season season_type team], body.keys.sort
    assert_equal 17, body["games"].size
    assert_equal "W", body["games"].first["result"]
    assert_equal [ %w[22 2026] ], client.team_seasons
  end

  test "GET /teams/:id/schedule?season= asks for that season" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/22/schedule", params: { season: "2026" } }

    assert_response :success
    assert_equal [ %w[22 2026] ], client.team_seasons
  end

  test "GET /teams/:id/schedule returns 404 for an unknown team and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/99999/schedule" }

    assert_response :not_found
    assert_equal({ "error" => "Team not found" }, response.parsed_body)
    assert_equal 0, client.calls
  end

  test "GET /teams/:id/schedule returns 404 for a bad or future season and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    [ "2027", "1990", "abc" ].each do |season|
      with_world(client) { get "/teams/22/schedule", params: { season: season } }

      assert_response :not_found
      assert_equal({ "error" => "Season not found" }, response.parsed_body)
    end
    assert_equal 0, client.calls
  end

  test "GET /teams/:id/schedule returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/teams/22/schedule" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
