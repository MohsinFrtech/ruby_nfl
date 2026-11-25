require "test_helper"

class TeamsControllerTest < ActionDispatch::IntegrationTest
  test "GET /teams returns the flattened teams as JSON" do
    raw = JSON.parse(file_fixture("nflteamlist.json").read)

    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(raw)) do
        get "/teams"
      end
    end

    assert_response :success
    teams = response.parsed_body["teams"]
    assert_equal 2, teams.size
    assert_equal %w[abbreviation color id location logo name nickname], teams.first.keys.sort
    assert_equal "Arizona Cardinals", teams.first["name"]
  end

  test "GET /teams returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_memory_cache do
      NflApiClient.stub(:new, failing) do
        get "/teams"
      end
    end

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
