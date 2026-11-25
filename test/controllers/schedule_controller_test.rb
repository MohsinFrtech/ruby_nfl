require "test_helper"

class ScheduleControllerTest < ActionDispatch::IntegrationTest
  setup do
    @raw = JSON.parse(file_fixture("nflschedule.json").binread)
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  test "GET /schedule returns the current week's games as JSON, sorted by kickoff" do
    with_world(FakeNflClient.new(@raw)) { get "/schedule" }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[fetched_at games season_type week year], body.keys.sort
    assert_equal 10, body["week"]
    assert_equal [ "WSH @ NYG", "NE VS DET", "KC @ ATL", "PIT @ CIN" ], body["games"].map { |g| g["short_name"] }
    assert_equal %w[away home], body["games"].first.slice("home", "away").keys.sort
  end

  test "GET /schedule serves the old schedule when the API fails after expiry" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      travel_to(Time.utc(2026, 11, 14, 9))
      get "/schedule"
      first_fetched_at = response.parsed_body["fetched_at"]
      client.response = NflApiClient::Error.new("down")

      travel_to(Time.utc(2026, 11, 14, 11)) # an hour of freshness has passed, backup lasts 3 more
      get "/schedule"

      assert_response :success
      assert_equal first_fetched_at, response.parsed_body["fetched_at"]
    end
  end

  test "GET /schedule returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/schedule" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end

  # --- GET /schedule/:year/:week ----------------------------------------------

  test "GET /schedule/:year/:week returns that week's games as JSON" do
    travel_to(Time.utc(2026, 11, 14, 9))
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/schedule/2026/10" }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[fetched_at games season_type week year], body.keys.sort
    assert_equal [ 2026, 10 ], [ body["year"], body["week"] ]
    assert_equal 4, body["games"].size
    assert_equal [ [ "2026", "10" ] ], client.weeks
  end

  test "GET /schedule/:year/:week returns 404 for a silly year or week and never calls RapidAPI" do
    travel_to(Time.utc(2026, 11, 14, 9))
    client = FakeNflClient.new(@raw)

    with_world(client) do
      %w[abc/1 2026/0 2026/19 1999/1 2026/01 20262/1 2026/abc 2030/1].each do |path|
        get "/schedule/#{path}"

        assert_response :not_found, "expected /schedule/#{path} to be refused"
        assert_equal({ "error" => "Schedule not found" }, response.parsed_body)
      end
    end

    assert_equal 0, client.calls
  end

  test "GET /schedule/:year/:week returns 404 when the NFL API has no such week" do
    travel_to(Time.utc(2026, 11, 14, 9))

    with_world(FakeNflClient.new(NflApiClient::NotFound.new("not found"))) { get "/schedule/2020/18" }

    assert_response :not_found
    assert_equal({ "error" => "Schedule not found" }, response.parsed_body)
  end

  test "GET /schedule/:year/:week returns 502 with a clean message when the NFL API fails" do
    travel_to(Time.utc(2026, 11, 14, 9))
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/schedule/2026/10" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.", response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end

  test "GET /schedule/:year/:week returns 502 when the API answers with a different week" do
    travel_to(Time.utc(2026, 11, 14, 9))

    with_world(FakeNflClient.new(@raw)) { get "/schedule/2026/3" } # the fake always answers week 10

    assert_response :bad_gateway
  end

  test "GET /schedule still returns the current week" do
    travel_to(Time.utc(2026, 11, 14, 9))
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/schedule" }

    assert_response :success
    assert_equal 1, client.calls
    assert_equal [], client.weeks # it did not use the chosen-week call
  end

  test "GET /schedule returns 502, not an empty 200, when the API sends no games" do
    with_world(FakeNflClient.new({})) { get "/schedule" }

    assert_response :bad_gateway
  end
end
