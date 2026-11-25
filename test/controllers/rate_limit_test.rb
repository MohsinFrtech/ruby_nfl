require "test_helper"

class RateLimitTest < ActionDispatch::IntegrationTest
  LIMIT = ApplicationController::REQUESTS_PER_MINUTE

  # Requests that are answered with a 404 straight away: no cache, no RapidAPI. Perfect for
  # counting, because they cost nothing and need no fake data.
  CHEAP_PATHS = %w[/players/abc /standings/1999 /schedule/abc/1].freeze

  def visit(path = "/players/abc", ip: nil)
    ip ? get(path, env: { "REMOTE_ADDR" => ip }) : get(path)
  end

  test "a visitor may make the allowed number of requests in a minute" do
    LIMIT.times do
      visit
      assert_response :not_found # 404 = the request got through to our code
    end
  end

  test "the next request is refused with a 429, a clear message and a Retry-After header" do
    LIMIT.times { visit }

    visit

    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_equal "Too many requests. Please slow down and try again in a minute.", response.parsed_body["error"]
  end

  test "the limit is for the whole API, not for each endpoint" do
    # 60 requests spread over three different endpoints...
    LIMIT.times { |i| visit(CHEAP_PATHS[i % CHEAP_PATHS.size]) }

    # ...and a fourth endpoint is already blocked
    visit "/teams/abc/players"
    assert_response :too_many_requests
  end

  test "different visitors are counted separately" do
    LIMIT.times { visit(ip: "203.0.113.10") }
    visit(ip: "203.0.113.10")
    assert_response :too_many_requests

    visit(ip: "203.0.113.11") # someone else is not affected
    assert_response :not_found
  end

  test "a refused request never reaches our code, so it cannot cost a RapidAPI call" do
    client = FakeNflClient.new({})
    LIMIT.times { visit }

    NflApiClient.stub(:new, client) { visit "/news" }

    assert_response :too_many_requests
    assert_equal 0, client.calls
  end

  test "the count starts again after a minute" do
    start = Time.utc(2026, 11, 14, 9)
    travel_to(start)
    LIMIT.times { visit }
    visit
    assert_response :too_many_requests

    travel_to(start + 61.seconds)
    visit
    assert_response :not_found
  end

  test "the health check is never limited" do
    (LIMIT + 40).times do
      get "/up"
      assert_response :success
    end
  end

  test "being limited does not stop the health check either" do
    LIMIT.times { visit }
    visit
    assert_response :too_many_requests

    get "/up"
    assert_response :success
  end

  test "the limit is 60 a minute" do
    assert_equal 60, LIMIT
  end

  test "each visitor has one counter, kept in the limiter's own store and not in the shared cache" do
    shared = ActiveSupport::Cache::MemoryStore.new

    Rails.stub(:cache, shared) { LIMIT.times { visit(ip: "203.0.113.20") } }

    assert_equal LIMIT, ApplicationController::RATE_LIMIT_STORE.read("rate-limit:api:203.0.113.20")
    assert_not shared.exist?("rate-limit:api:203.0.113.20")
  end
end
