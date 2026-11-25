require "test_helper"

class NewsControllerTest < ActionDispatch::IntegrationTest
  test "GET /news returns fetched_at and the cleaned articles as JSON" do
    raw = JSON.parse(file_fixture("nfl-news.json").binread)

    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(raw)) do
        get "/news"
      end
    end

    assert_response :success
    body = response.parsed_body
    assert_equal %w[articles fetched_at], body.keys.sort
    assert_equal 3, body["articles"].size
    assert_includes body["articles"].first["headline"], "Jameis Winston" # newest article comes first
    assert_equal %w[byline headline id image players published_at summary teams type url],
                 body["articles"].first.keys.sort
  end

  test "GET /news still returns 200 with the old news when the API fails after expiry" do
    raw = JSON.parse(file_fixture("nfl-news.json").binread)

    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(raw)) { get "/news" }
      first_fetched_at = response.parsed_body["fetched_at"]

      travel(8.hours + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new(NflApiClient::Error.new("down"))) { get "/news" }

        assert_response :success
        assert_equal first_fetched_at, response.parsed_body["fetched_at"] # old data, honestly dated
        assert_equal 3, response.parsed_body["articles"].size
      end
    end
  end

  test "GET /news returns 502 with a clean message when the NFL API fails" do
    failing = FakeNflClient.new(NflApiClient::Error.new("secret internal detail"))

    with_memory_cache do
      NflApiClient.stub(:new, failing) do
        get "/news"
      end
    end

    assert_response :bad_gateway
    assert_equal "Could not load NFL data right now. Please try again later.",
                 response.parsed_body["error"]
    assert_not_includes response.body, "secret internal detail"
  end
end
