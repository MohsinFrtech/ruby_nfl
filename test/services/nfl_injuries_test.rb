require "test_helper"

class NflInjuriesTest < ActiveSupport::TestCase
  setup do
    # binread + JSON.parse mimics the real client: Net::HTTP hands us raw bytes.
    @raw = JSON.parse(file_fixture("injuries.json").binread)
  end

  def team(name)
    NflInjuries.from_api(@raw).find { |t| t[:team] == name }
  end

  # --- from_api: flattening ------------------------------------------------

  test "from_api groups injuries by team and keeps the API's team order" do
    teams = NflInjuries.from_api(@raw)

    assert_equal [ "Arizona Cardinals", "Atlanta Falcons" ], teams.map { |t| t[:team] }
    assert_equal [ 3, 2 ], teams.map { |t| t[:injuries].size }
    assert_match %r{ari\.png\z}, teams.first[:logo]
  end

  test "from_api turns each injury into a small clean hash" do
    injury = team("Arizona Cardinals")[:injuries].first

    assert_equal %i[comment date headshot player player_id position status status_code url], injury.keys.sort
    assert_equal "Hjalte Froholdt", injury[:player]
    assert_equal "C", injury[:position]
    assert_equal "Questionable", injury[:status]
    assert_equal "Q", injury[:status_code]
    assert_equal "Nov 15", injury[:date]
    assert_match %r{\Ahttps://www\.espn\.com/nfl/player/}, injury[:url]
    assert_match %r{\.png\z}, injury[:headshot]
    assert_includes injury[:comment], "concussion"
  end

  test "from_api uses the real status names and short codes" do
    injuries = team("Atlanta Falcons")[:injuries]

    assert_equal [ "Questionable", "Out" ], injuries.map { |i| i[:status] }
    assert_equal [ "Q", "O" ], injuries.map { |i| i[:status_code] }
  end

  test "from_api gives nil for an empty comment, not an empty string" do
    blank = team("Atlanta Falcons")[:injuries].first

    assert_nil blank[:comment]
  end

  test "from_api tolerates missing athlete details" do
    raw_item = @raw["data"].first["items"].first
    raw_item.delete("athlete")
    raw_item.delete("type")

    injury = NflInjuries.from_api(@raw).first[:injuries].first
    assert_nil injury[:player]
    assert_nil injury[:url]
    assert_nil injury[:headshot]
    assert_nil injury[:status_code]
  end

  test "from_api tolerates a team with no items" do
    @raw["data"].first.delete("items")

    assert_equal [], NflInjuries.from_api(@raw).first[:injuries]
  end

  test "from_api reads the player id from the player link, for GET /players/:id" do
    injury = team("Arizona Cardinals")[:injuries].first

    assert_equal "3886633", injury[:player_id]
  end

  test "from_api gives nil for the player id when the link has none" do
    athlete = @raw["data"].first["items"].first["athlete"]

    [ nil, "", "https://www.espn.com/nfl/player/_/name/someone", "https://x.com/id/007/abc", "https://x.com/id/12abc" ].each do |href|
      athlete["href"] = href
      assert_nil NflInjuries.from_api(@raw).first[:injuries].first[:player_id], "expected no id in #{href.inspect}"
    end
  end

  test "from_api skips broken teams and injuries and treats broken pieces as missing" do
    first = @raw["data"].first
    first["items"] = [ nil, "junk" ] + first["items"]
    first["items"].last["type"] = "junk"
    first["items"].last["athlete"]["logo"] = "junk"
    @raw["data"] << nil << "junk"

    teams = NflInjuries.from_api(@raw)
    assert_equal [ "Arizona Cardinals", "Atlanta Falcons" ], teams.map { |t| t[:team] }
    assert_equal 3, teams.first[:injuries].size

    broken = teams.first[:injuries].last
    assert_nil broken[:status_code]
    assert_nil broken[:headshot]
    assert_not_nil broken[:player] # the rest of the injury is still there
  end

  test "from_api returns an empty list for an unexpected response" do
    assert_equal [], NflInjuries.from_api({ "status" => "error", "data" => nil })
    assert_equal [], NflInjuries.from_api([])
    assert_equal [], NflInjuries.from_api(nil)
  end

  # --- latest: caching -----------------------------------------------------

  test "latest includes fetched_at and the teams" do
    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) do
        freeze_time do
          result = NflInjuries.latest

          assert_equal Time.current.utc.iso8601, result[:fetched_at]
          assert_equal 2, result[:teams].size
        end
      end
    end
  end

  test "latest calls the API once, then serves from the cache" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        first = NflInjuries.latest
        second = NflInjuries.latest

        assert_equal first, second
      end

      assert_equal 1, client.calls
    end
  end

  test "latest is still cached just before 8 hours" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        NflInjuries.latest
        travel(7.hours + 59.minutes) { NflInjuries.latest }
      end

      assert_equal 1, client.calls
    end
  end

  test "latest makes a fresh API call after 8 hours" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        NflInjuries.latest
        travel(8.hours + 1.minute) { NflInjuries.latest }
      end

      assert_equal 2, client.calls
    end
  end

  test "latest serves the old report when the API fails after 8 hours" do
    with_memory_cache do
      old = nil
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) { old = NflInjuries.latest }

      travel(8.hours + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new(NflApiClient::Error.new("down"))) do
          assert_equal old, NflInjuries.latest
        end
      end
    end
  end

  test "latest does not cache a failure" do
    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(NflApiClient::Error.new("boom"))) do
        assert_raises(NflApiClient::Error) { NflInjuries.latest }
      end
      assert_not Rails.cache.exist?(NflInjuries::CACHE_KEY)
      travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown before asking again

      NflApiClient.stub(:new, FakeNflClient.new(@raw)) do
        assert_equal 2, NflInjuries.latest[:teams].size
      end
    end
  end

  test "latest does not cache a report with no teams" do
    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new({ "status" => "success", "data" => [] })) do
        assert_raises(NflApiClient::Error) { NflInjuries.latest }
      end
      assert_not Rails.cache.exist?(NflInjuries::CACHE_KEY)
    end
  end

  test "latest serves the old report when the API sends no teams after 8 hours" do
    with_memory_cache do
      old = nil
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) { old = NflInjuries.latest }

      travel(8.hours + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new({ "status" => "success", "data" => [] })) do
          assert_equal old, NflInjuries.latest
        end
      end
    end
  end

  test "latest keeps a team that has no injuries" do
    @raw["data"].first["items"] = []

    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) do
        assert_equal [], NflInjuries.latest[:teams].first[:injuries]
      end
    end
  end
end
