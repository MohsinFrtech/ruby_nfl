require "test_helper"

class PlayersControllerTest < ActionDispatch::IntegrationTest
  PLAYER_ID = "4685720".freeze

  setup do
    @raw = JSON.parse(file_fixture("player-overview.json").binread)
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  test "GET /players/:id returns the player's sections as JSON" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/players/#{PLAYER_ID}" }

    assert_response :success
    body = response.parsed_body
    assert_equal PLAYER_ID, body["player_id"]
    assert_equal %w[awards fantasy fetched_at game_log news next_game player_id rotowire statistics],
                 body.keys.sort
    assert_equal "Carolina Panthers at New Orleans Saints", body["next_game"]["name"]
    assert_equal [ PLAYER_ID ], client.team_ids
  end

  test "GET /players/:id returns 404 for a badly formed id and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      %w[abc 007 1e3 12345678901].each do |bad_id|
        get "/players/#{bad_id}"

        assert_response :not_found, "expected #{bad_id} to be refused"
        assert_equal({ "error" => "Player not found" }, response.parsed_body)
      end
    end

    assert_equal 0, client.calls
  end

  test "GET /players/:id returns 404 when the NFL API says the player does not exist" do
    client = FakeNflClient.new(NflApiClient::NotFound.new("not found"))

    with_world(client) { get "/players/123456" }

    assert_response :not_found
    assert_equal({ "error" => "Player not found" }, response.parsed_body)
  end

  test "GET /players/:id returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/players/#{PLAYER_ID}" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end

  test "GET /players/:id returns 503 with Retry-After when today's lookup budget is used up" do
    client = FakeNflClient.new(@raw)

    travel_to(Time.utc(2026, 11, 25, 23, 0)) do
      with_world(client) do
        Rails.cache.write(NflPlayerOverview.budget_key, NflPlayerOverview::DAILY_LOOKUPS, expires_in: 2.days)
        get "/players/#{PLAYER_ID}"
      end
    end

    assert_response :service_unavailable
    assert_equal "Player lookups are paused for today. Please try again tomorrow.", response.parsed_body["error"]
    assert_equal "3600", response.headers["Retry-After"] # one hour until midnight UTC
    assert_equal 0, client.calls
  end
end
