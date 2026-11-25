require "test_helper"

class NflTeamsTest < ActiveSupport::TestCase
  setup do
    @raw = JSON.parse(file_fixture("nflteamlist.json").read)
  end

  # --- from_api: flattening ------------------------------------------------

  test "from_api flattens the nested response into a list of teams" do
    teams = NflTeams.from_api(@raw)

    assert_equal 2, teams.size
    assert_equal(
      { id: "22", name: "Arizona Cardinals", abbreviation: "ARI",
        location: "Arizona", nickname: "Cardinals", color: "#a40227",
        logo: "https://a.espncdn.com/i/teamlogos/nfl/500/ari.png" },
      teams.first
    )
  end

  test "from_api picks the default logo, not just the first one" do
    team = @raw.dig("sports", 0, "leagues", 0, "teams", 0, "team")
    team["logos"].reverse! # now the default logo is no longer first

    assert_match %r{/500/ari\.png\z}, NflTeams.from_api(@raw).first[:logo]
  end

  test "from_api gives nil color and logo when the API omits them" do
    team = @raw.dig("sports", 0, "leagues", 0, "teams", 0, "team")
    team.delete("color")
    team.delete("logos")

    result = NflTeams.from_api(@raw).first
    assert_nil result[:color]
    assert_nil result[:logo]
  end

  test "from_api returns an empty list for an unexpected response" do
    assert_equal [], NflTeams.from_api({})
  end

  test "from_api skips broken entries instead of crashing" do
    good_ids = NflTeams.from_api(@raw).map { |team| team[:id] }

    entries = @raw.dig("sports", 0, "leagues", 0, "teams")
    entries << {}                                          # no "team"
    entries << { "team" => { "displayName" => "No Id" } }  # team without an id
    entries << "junk"                                      # not even a Hash
    entries.first["team"]["logos"].unshift({ "href" => "https://example.com/no-rel.png" }) # logo without "rel"

    result = NflTeams.from_api(@raw)
    assert_equal good_ids, result.map { |team| team[:id] }
    assert_match %r{/500/ari\.png\z}, result.first[:logo]
  end

  # --- all: caching --------------------------------------------------------

  test "all calls the API once, then serves from the cache" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        first = NflTeams.all
        second = NflTeams.all

        assert_equal first, second
      end

      assert_equal 1, client.calls
    end
  end

  test "all still serves from the cache just before 7 days" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        NflTeams.all
        travel(6.days + 23.hours) { NflTeams.all }
      end

      assert_equal 1, client.calls
    end
  end

  test "all makes a fresh API call after 7 days" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        NflTeams.all
        travel(7.days + 1.minute) { NflTeams.all }
      end

      assert_equal 2, client.calls
    end
  end

  test "all serves the old teams when the API fails after 7 days" do
    with_memory_cache do
      old = nil
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) { old = NflTeams.all }

      travel(7.days + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new(NflApiClient::Error.new("down"))) do
          assert_equal old, NflTeams.all
        end
      end
    end
  end

  # --- find!: looking up one team ------------------------------------------

  test "find! returns the team with that id" do
    teams = NflTeams.from_api(@raw)

    NflTeams.stub(:all, teams) do
      assert_equal teams.first, NflTeams.find!(teams.first[:id])
      assert_equal teams.last, NflTeams.find!(teams.last[:id])
    end
  end

  test "find! accepts a number as well as text" do
    teams = NflTeams.from_api(@raw)

    NflTeams.stub(:all, teams) do
      assert_equal teams.first, NflTeams.find!(teams.first[:id].to_i)
    end
  end

  test "find! raises UnknownTeam for an unknown, malformed or blank id" do
    teams = NflTeams.from_api(@raw)

    NflTeams.stub(:all, teams) do
      [ "99999", "abc", "", nil, "0", "022", " 22", "22 ", "22;", "-1" ].each do |bad_id|
        assert_raises(NflTeams::UnknownTeam, "expected #{bad_id.inspect} to be refused") do
          NflTeams.find!(bad_id)
        end
      end
    end
  end

  test "all does not cache a failure" do
    with_memory_cache do
      failing = FakeNflClient.new(NflApiClient::Error.new("boom"))

      NflApiClient.stub(:new, failing) do
        assert_raises(NflApiClient::Error) { NflTeams.all }
      end
      assert_not Rails.cache.exist?(NflTeams::CACHE_KEY)
      travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown before asking again

      working = FakeNflClient.new(@raw)
      NflApiClient.stub(:new, working) do
        assert_equal 2, NflTeams.all.size
      end
    end
  end

  test "all does not cache an empty team list" do
    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new({})) do
        assert_raises(NflApiClient::Error) { NflTeams.all }
      end
      assert_not Rails.cache.exist?(NflTeams::CACHE_KEY)
    end
  end

  test "all serves the old teams when the API sends an empty list after 7 days" do
    with_memory_cache do
      old = nil
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) { old = NflTeams.all }

      travel(7.days + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new({})) do
          assert_equal old, NflTeams.all
        end
      end
    end
  end
end
