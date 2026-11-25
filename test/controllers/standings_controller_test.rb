require "test_helper"

class StandingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    travel_to(Time.utc(2026, 11, 14, 9))
    @raw = JSON.parse(file_fixture("standings.json").binread)
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  test "GET /standings/:year returns the divisions and teams as JSON" do
    client = FakeNflClient.new(@raw)

    with_world(client) { get "/standings/2026" }

    assert_response :success
    body = response.parsed_body
    assert_equal %w[divisions fetched_at year], body.keys.sort
    assert_equal 2026, body["year"]
    assert_equal [ "AFC East", "NFC East", "NFC South", "NFC West" ], body["divisions"].map { |d| d["name"] }
    assert_equal "Buffalo Bills", body["divisions"].first["teams"].first["team"]["name"]
    assert_equal [ "2026" ], client.team_ids
  end

  test "GET /standings returns the current season's table" do
    client = FakeNflClient.new(@raw)

    NflSchedule.stub(:current, { year: 2026 }) do
      with_world(client) { get "/standings" }
    end

    assert_response :success
    assert_equal 2026, response.parsed_body["year"]
    assert_equal [ "2026" ], client.team_ids
  end

  test "GET /standings/:year returns 404 for a silly year and never calls RapidAPI" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      %w[abc 2001 1999 2027 02026 20262 2e3].each do |year|
        get "/standings/#{year}"

        assert_response :not_found, "expected /standings/#{year} to be refused"
        assert_equal({ "error" => "Standings not found" }, response.parsed_body)
      end
    end

    assert_equal 0, client.calls
  end

  test "GET /standings/:year returns 404 when the API answers with a different season" do
    with_world(FakeNflClient.new(@raw)) { get "/standings/2025" } # the fake always answers season 2026

    assert_response :not_found
    assert_equal({ "error" => "Standings not found" }, response.parsed_body)
  end

  test "GET /standings/:year returns 404 when the API says it has no such season" do
    with_world(FakeNflClient.new(NflApiClient::NotFound.new("not found"))) { get "/standings/2020" }

    assert_response :not_found
  end

  test "GET /standings/:year returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_world(failing) { get "/standings/2026" }

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.", response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end

  test "GET /standings returns 502 when the current season cannot be determined" do
    NflSchedule.stub(:current, { year: nil }) do
      with_world(FakeNflClient.new(@raw)) { get "/standings" }
    end

    assert_response :bad_gateway
  end

  test "GET /standings serves the old table when the API fails after expiry" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      get "/standings/2026"
      first_fetched_at = response.parsed_body["fetched_at"]
      client.response = NflApiClient::Error.new("down")

      travel_to(Time.utc(2026, 11, 14, 18)) # 9 hours later: the 8 hours are over, the backup is not
      get "/standings/2026"

      assert_response :success
      assert_equal first_fetched_at, response.parsed_body["fetched_at"]
    end
  end
end
