require "test_helper"

class GamesControllerTest < ActionDispatch::IntegrationTest
  GAME_ID = "401872926".freeze

  setup do
    @raw = JSON.parse(file_fixture("game-summary.json").binread)
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  test "GET /games/:id returns the game as JSON" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/games/#{GAME_ID}" }

    assert_response :success
    body = response.parsed_body
    assert_equal GAME_ID, body["id"]
    assert_equal [ 14, 26 ], body["teams"].map { |t| t["score"] }
    assert_equal 8, body["scoring_plays"].size
    assert_equal [ GAME_ID ], client.team_ids
  end

  test "GET /games/:id returns 404 for a badly formed id and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    [ "abc", "007", "-5" ].each do |bad|
      with_world(client) { get "/games/#{bad}" }

      assert_response :not_found
      assert_equal({ "error" => "Game not found" }, response.parsed_body)
    end
    assert_equal 0, client.calls
  end

  test "GET /games/:id returns 404 when RapidAPI does not know the game" do
    with_world(FakeNflClient.new(NflApiClient::NotFound.new("no such game"))) { get "/games/999999999" }

    assert_response :not_found
    assert_equal({ "error" => "Game not found" }, response.parsed_body)
  end

  test "GET /games/:id returns 503 with Retry-After when today's budget is used up" do
    travel_to(Time.utc(2026, 11, 25, 23, 0))

    with_world(FakeNflClient.new(@raw)) do
      Rails.cache.write(NflGameSummary.budget_key, NflGameSummary::DAILY_LOOKUPS, expires_in: 2.days)
      get "/games/#{GAME_ID}"
    end

    assert_response :service_unavailable
    assert_equal "Game lookups are paused for today. Please try again tomorrow.", response.parsed_body["error"]
    assert_equal "3600", response.headers["Retry-After"]
  end

  test "GET /games/:id returns 502 with a clean message when the NFL API fails" do
    with_world(FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))) { get "/games/#{GAME_ID}" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
