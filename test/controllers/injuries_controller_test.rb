require "test_helper"

class InjuriesControllerTest < ActionDispatch::IntegrationTest
  test "GET /injuries returns fetched_at and the teams with their injuries as JSON" do
    raw = JSON.parse(file_fixture("injuries.json").binread)

    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(raw)) do
        get "/injuries"
      end
    end

    assert_response :success
    body = response.parsed_body
    assert_equal %w[fetched_at teams], body.keys.sort
    assert_equal 2, body["teams"].size
    assert_equal %w[injuries logo team], body["teams"].first.keys.sort
    assert_equal "Arizona Cardinals", body["teams"].first["team"]
    assert_equal "Hjalte Froholdt", body["teams"].first["injuries"].first["player"]
  end

  test "GET /injuries returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_memory_cache do
      NflApiClient.stub(:new, failing) do
        get "/injuries"
      end
    end

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
