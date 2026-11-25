require "test_helper"

class StaleCacheTest < ActiveSupport::TestCase
  KEY = "test/thing".freeze
  TTL = 8.hours
  GRACE = 1.day

  # Runs StaleCache.fetch with a block that either returns a value or raises.
  # `calls` counts how many times the (pretend) API was really called.
  def fetch_with(outcome)
    @calls = 0
    StaleCache.fetch(KEY, expires_in: TTL, grace: GRACE) do
      @calls += 1
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
  end

  def upstream_down = NflApiClient::Error.new("API is down")

  # --- normal behaviour is unchanged ----------------------------------------

  test "returns the fresh value and only calls the API once" do
    with_memory_cache do
      assert_equal "v1", fetch_with("v1")
      assert_equal "v1", fetch_with("v2") # served from cache: block not run
      assert_equal 0, @calls
    end
  end

  test "fetches again after the cache time" do
    with_memory_cache do
      fetch_with("v1")
      travel(TTL + 1.minute) { assert_equal "v2", fetch_with("v2") }
      assert_equal 1, @calls
    end
  end

  # --- the safety net -------------------------------------------------------

  test "serves the backup when the API fails after the cache expired" do
    with_memory_cache do
      fetch_with("v1")

      travel(TTL + 1.minute) do
        assert_equal "v1", fetch_with(upstream_down)
      end
    end
  end

  test "raises when the API fails and there is no backup yet" do
    with_memory_cache do
      assert_raises(NflApiClient::Error) { fetch_with(upstream_down) }
    end
  end

  test "backup is served up to the grace period, but not beyond" do
    with_memory_cache do
      fetch_with("v1")

      travel(TTL + GRACE - 1.minute) do
        assert_equal "v1", fetch_with(upstream_down)
      end
    end

    with_memory_cache do
      fetch_with("v1")

      travel(TTL + GRACE + 1.minute) do
        assert_raises(NflApiClient::Error) { fetch_with(upstream_down) }
      end
    end
  end

  test "does not hammer a broken API: waits before trying again" do
    with_memory_cache do
      start = Time.current
      fetch_with("v1")

      # travel_to WITHOUT a block moves the clock; blocks cannot be nested.
      travel_to(start + TTL + 1.minute)
      assert_equal "v1", fetch_with(upstream_down)
      assert_equal 1, @calls # first visitor tried the API and failed

      travel_to(start + TTL + 1.minute + StaleCache::RETRY_AFTER - 1.minute)
      assert_equal "v1", fetch_with(upstream_down)
      assert_equal 0, @calls # backup served, API NOT called

      travel_to(start + TTL + 1.minute + StaleCache::RETRY_AFTER + 1.minute)
      assert_equal "v1", fetch_with(upstream_down)
      assert_equal 1, @calls # waited long enough: tried the API again
    end
  end

  test "recovers: once the API works again, fresh data replaces the backup" do
    with_memory_cache do
      fetch_with("v1")

      travel(TTL + 1.minute) do
        assert_equal "v1", fetch_with(upstream_down) # outage
      end

      travel(TTL + StaleCache::RETRY_AFTER + 1.minute) do
        assert_equal "v2", fetch_with("v2")          # API is back
        assert_equal "v2", fetch_with(upstream_down) # and v2 is now cached
      end
    end
  end

  test "does not hide bugs: other errors are not swallowed" do
    with_memory_cache do
      fetch_with("v1")

      travel(TTL + 1.minute) do
        assert_raises(ZeroDivisionError) { fetch_with(ZeroDivisionError.new("bug in our code")) }
      end
    end
  end

  # --- time decided by the data (the schedule's mode) ------------------------

  DATA_KEY = "test/data_decided".freeze

  # The block's value is a Hash; expires_in and grace are functions of it.
  def fetch_by_data(outcome, expires_in: ->(data) { data[:ttl] }, grace: ->(data) { data[:grace] })
    @calls = 0
    StaleCache.fetch(DATA_KEY, expires_in: expires_in, grace: grace) do
      @calls += 1
      raise outcome if outcome.is_a?(Exception)
      outcome
    end
  end

  test "by-data mode keeps each answer for the time that answer asks for" do
    with_memory_cache do
      start = Time.current
      fetch_by_data({ ttl: 1.minute, grace: 1.hour })

      travel_to(start + 59.seconds)
      fetch_by_data({ ttl: 1.minute, grace: 1.hour })
      assert_equal 0, @calls # still fresh

      travel_to(start + 61.seconds)
      fetch_by_data({ ttl: 1.minute, grace: 1.hour })
      assert_equal 1, @calls # a minute has passed
    end

    with_memory_cache do
      start = Time.current
      fetch_by_data({ ttl: 1.day, grace: 1.hour })

      travel_to(start + 23.hours)
      fetch_by_data({ ttl: 1.day, grace: 1.hour })
      assert_equal 0, @calls # this answer asked for a whole day
    end
  end

  test "by-data mode serves the backup for the grace that the data asked for, then gives up" do
    answer = { ttl: 1.minute, grace: 10.minutes }

    with_memory_cache do
      start = Time.current
      fetch_by_data(answer)
      travel_to(start + 1.minute + 9.minutes)
      assert_equal answer, fetch_by_data(upstream_down)
    end

    with_memory_cache do
      start = Time.current
      fetch_by_data(answer)
      travel_to(start + 1.minute + 11.minutes)
      assert_raises(NflApiClient::Error) { fetch_by_data(upstream_down) }
    end
  end

  test "by-data mode raises when the API fails and there is no backup yet" do
    with_memory_cache do
      assert_raises(NflApiClient::Error) { fetch_by_data(upstream_down) }
      assert_not Rails.cache.exist?(DATA_KEY)
    end
  end

  test "by-data mode waits before trying a broken API again" do
    answer = { ttl: 1.minute, grace: 1.hour }

    with_memory_cache do
      start = Time.current
      fetch_by_data(answer)

      travel_to(start + 2.minutes)
      assert_equal answer, fetch_by_data(upstream_down)
      assert_equal 1, @calls # tried the API and failed

      travel_to(start + 2.minutes + StaleCache::RETRY_AFTER - 1.minute)
      fetch_by_data(upstream_down)
      assert_equal 0, @calls # backup served without asking the API

      travel_to(start + 2.minutes + StaleCache::RETRY_AFTER + 1.minute)
      fetch_by_data(upstream_down)
      assert_equal 1, @calls # waited long enough
    end
  end

  test "by-data mode accepts a plain duration for grace" do
    with_memory_cache do
      start = Time.current
      fetch_by_data({ ttl: 1.minute }, grace: 1.hour)

      travel_to(start + 30.minutes)
      assert_equal({ ttl: 1.minute }, fetch_by_data(upstream_down, grace: 1.hour))
    end
  end

  test "by-data mode does not hide bugs: other errors are not swallowed" do
    with_memory_cache do
      start = Time.current
      fetch_by_data({ ttl: 1.minute, grace: 1.hour })

      travel_to(start + 2.minutes)
      assert_raises(ZeroDivisionError) { fetch_by_data(ZeroDivisionError.new("bug")) }
    end
  end

  test "logs a warning when it serves a backup" do
    with_memory_cache do
      fetch_with("v1")
      logged = StringIO.new
      old_logger = Rails.logger
      Rails.logger = Logger.new(logged)

      begin
        travel(TTL + 1.minute) { fetch_with(upstream_down) }
      ensure
        Rails.logger = old_logger
      end

      assert_match "serving backup copy", logged.string
      assert_match "API is down", logged.string
    end
  end

  # --- no backup: cool down instead of calling the API for every visitor ------

  test "with no backup, a failure pauses API calls for a minute, then tries again" do
    with_memory_cache do
      assert_raises(NflApiClient::Error) { fetch_with(upstream_down) }
      assert_equal 1, @calls

      # Within the minute: the error comes at once, without calling the API.
      travel(StaleCache::FAILURE_COOLDOWN - 1.second) do
        error = assert_raises(NflApiClient::Error) { fetch_with("v1") }
        assert_match "cooling down", error.message
        assert_equal 0, @calls
      end

      # After the minute: the API is asked again, and a good answer is used normally.
      travel(StaleCache::FAILURE_COOLDOWN + 1.second) do
        assert_equal "v1", fetch_with("v1")
        assert_equal 1, @calls
      end
    end
  end

  test "by-data mode also cools down after a failure with no backup" do
    with_memory_cache do
      calls = 0
      fetch = lambda do |outcome|
        StaleCache.fetch(KEY, expires_in: ->(_data) { TTL }, grace: GRACE) do
          calls += 1
          raise outcome if outcome.is_a?(Exception)
          outcome
        end
      end

      assert_raises(NflApiClient::Error) { fetch.call(upstream_down) }
      assert_raises(NflApiClient::Error) { fetch.call("v1") }
      assert_equal 1, calls
    end
  end

  test "a not-found answer does not start a cooldown" do
    with_memory_cache do
      2.times { assert_raises(NflApiClient::NotFound) { fetch_with(NflApiClient::NotFound.new("no such thing")) } }
      assert_equal 1, @calls # the second call reached the API too (this counter resets per fetch)
    end
  end
end
