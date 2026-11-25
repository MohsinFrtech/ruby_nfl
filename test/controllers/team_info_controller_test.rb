require "test_helper"

class TeamInfoControllerTest < ActionDispatch::IntegrationTest
  setup do
    @raw = JSON.parse(file_fixture("team-info.json").binread)
    @teams = NflTeams.from_api(JSON.parse(file_fixture("nflteamlist.json").binread))
  end

  def with_world(client)
    with_memory_cache do
      NflTeams.stub(:all, @teams) do
        NflApiClient.stub(:new, client) { yield }
      end
    end
  end

  test "GET /teams/:id returns the team's details as JSON" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/teams/22" }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[fetched_at next_game record standing team venue], body.keys.sort
    assert_equal "Arizona Cardinals", body["team"]["name"]
    assert_equal "3-8", body["record"]["total"]["summary"]
    assert_equal [ "22" ], client.team_ids
  end

  test "GET /teams/:id returns 404 for an unknown team and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    [ "99999", "abc" ].each do |bad_id|
      with_world(client) { get "/teams/#{bad_id}" }

      assert_response :not_found
      assert_equal({ "error" => "Team not found" }, response.parsed_body)
    end
    assert_equal 0, client.calls
  end

  test "GET /teams/:id returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/teams/22" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
