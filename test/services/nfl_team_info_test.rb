require "test_helper"

class NflTeamInfoTest < ActiveSupport::TestCase
  setup do
    # A real answer for team 22 (Arizona Cardinals), the first team in nflteamlist.json.
    @raw = JSON.parse(file_fixture("team-info.json").binread)
    @teams = NflTeams.from_api(JSON.parse(file_fixture("nflteamlist.json").binread))
    @team = @teams.find { |t| t[:id] == "22" }
    @other_team = @teams.find { |t| t[:id] != "22" }
  end

  # Runs the block with: a memory cache, a known list of teams, and a fake RapidAPI client.
  def with_world(client)
    with_memory_cache do
      NflTeams.stub(:all, @teams) do
        NflApiClient.stub(:new, client) { yield }
      end
    end
  end

  def info = NflTeamInfo.from_api(@raw)

  # --- from_api: shaping the data -------------------------------------------

  test "from_api returns the team, standing, record, venue and next game" do
    assert_equal %i[next_game record standing team venue], info.keys.sort
    assert_equal "4th in NFC West", info[:standing]
  end

  test "from_api gives the team's details in a small clean shape" do
    team = info[:team]

    assert_equal %i[abbreviation alternate_color color id location logo logo_dark name nickname url], team.keys.sort
    assert_equal "22", team[:id]
    assert_equal "Arizona Cardinals", team[:name]
    assert_equal "#a40227", team[:color]
    assert_equal "#ffffff", team[:alternate_color]
    assert_equal "https://a.espncdn.com/i/teamlogos/nfl/500/ari.png", team[:logo]
    assert_equal "https://a.espncdn.com/i/teamlogos/nfl/500-dark/ari.png", team[:logo_dark]
    assert_match %r{\Ahttps://www\.espn\.com/nfl/team/}, team[:url]
  end

  test "from_api gives the total, home and road record, with points and streak only in the total" do
    record = info[:record]

    assert_equal %i[home road total], record.keys.sort
    assert_equal "3-8", record[:total][:summary]
    assert_equal 3, record[:total][:wins]
    assert_equal 8, record[:total][:losses]
    assert_equal 191, record[:total][:points_for]
    assert_equal(-3, record[:total][:streak])
    assert_equal 0.2727, record[:total][:win_percent] # 0.27272728 rounded
    assert_equal %i[losses summary ties win_percent wins], record[:home].keys.sort
    assert_equal "0-4", record[:home][:summary]
    assert_equal "3-4", record[:road][:summary]
  end

  test "from_api gives the venue with its outside picture" do
    venue = info[:venue]

    assert_equal "State Farm Stadium", venue[:name]
    assert_equal "Glendale", venue[:city]
    assert_equal "AZ", venue[:state]
    assert venue[:indoor]
    assert_equal "https://a.espncdn.com/i/venues/nfl/day/3970.jpg", venue[:image] # not the interior one
  end

  test "from_api gives the next game" do
    game = info[:next_game]

    assert_equal "401873092", game[:id]
    assert_equal "WSH @ ARI", game[:short_name]
    assert_equal "2026-11-29T21:25Z", game[:date]
    assert_equal 12, game[:week]
    assert_equal "pre", game[:status]
    assert_equal [ "Fox" ], game[:broadcasts]
    assert_equal [ %w[22 home], %w[28 away] ], game[:teams].map { |t| [ t[:id], t[:home_away] ] }
  end

  test "from_api gives nil for a next game when the season is over" do
    @raw["team"]["nextEvent"] = []

    assert_nil info[:next_game]
  end

  test "from_api does not copy the 17 logos and 14 links" do
    json = info.to_json

    assert_not_includes json, "grayscale"
    assert_not_includes json, "depthchart"
  end

  test "from_api gives nil parts for an unexpected response" do
    [ { "message" => "oops" }, nil, [], { "team" => "junk" } ].each do |raw|
      result = NflTeamInfo.from_api(raw)

      assert_nil result[:team][:id], "for #{raw.inspect}"
      assert_nil result[:record]
      assert_nil result[:venue]
      assert_nil result[:next_game]
    end
  end

  test "from_api skips broken pieces instead of crashing" do
    team = @raw["team"]
    team["logos"] = [ nil, "junk" ] + team["logos"]
    team["links"] = [ nil, 42 ] + team["links"]
    team["record"]["items"] = [ nil, "junk", { "type" => nil } ] + team["record"]["items"]
    team["record"]["items"].last["stats"] = [ nil, "junk", { "name" => "wins", "value" => "three" } ]
    team["franchise"]["venue"]["address"] = "junk"
    team["nextEvent"].first["competitions"].first["competitors"] << nil << "junk"
    team["nextEvent"].first["competitions"].first["broadcasts"] << nil << { "media" => "junk" }

    result = nil
    assert_nothing_raised { result = NflTeamInfo.from_api(@raw) }
    assert_equal "https://a.espncdn.com/i/teamlogos/nfl/500/ari.png", result[:team][:logo]
    assert_equal "3-8", result[:record][:total][:summary]
    assert_nil result[:record][:road][:wins] # "three" is not a number
    assert_nil result[:venue][:city]
    assert_equal 2, result[:next_game][:teams].size
    assert_equal [ "Fox" ], result[:next_game][:broadcasts]
  end

  test "from_api treats a broken record, venue and next game as missing" do
    @raw["team"].merge!("record" => "junk", "franchise" => nil, "nextEvent" => "junk")

    assert_nil info[:record]
    assert_nil info[:venue]
    assert_nil info[:next_game]
  end

  # --- for: one team, cached per team ---------------------------------------

  test "for returns fetched_at and the team's details" do
    freeze_time do
      with_world(FakeNflClient.new(@raw)) do
        result = NflTeamInfo.for(@team[:id])

        assert_equal Time.current.utc.iso8601, result[:fetched_at]
        assert_equal "Arizona Cardinals", result[:team][:name]
        assert_equal "3-8", result[:record][:total][:summary]
      end
    end
  end

  test "for asks RapidAPI about the right team, and accepts a number as well as text" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamInfo.for(@team[:id])
      Rails.cache.clear
      NflTeamInfo.for(@team[:id].to_i)
    end

    assert_equal [ @team[:id], @team[:id] ], client.team_ids
  end

  test "for calls the API once, then serves from the cache" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      first = NflTeamInfo.for(@team[:id])
      assert_equal first, NflTeamInfo.for(@team[:id])
    end

    assert_equal 1, client.calls
  end

  test "for refuses an unknown team without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      [ "99999", "abc", "", nil, "0", "1; DROP TABLE", "022" ].each do |bad_id|
        assert_raises(NflTeams::UnknownTeam, "expected #{bad_id.inspect} to be refused") do
          NflTeamInfo.for(bad_id)
        end
        assert_not Rails.cache.exist?(NflTeamInfo.cache_key(bad_id))
      end
    end

    assert_equal 0, client.calls
  end

  test "for refuses an answer about a different team and caches nothing" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      assert_raises(NflApiClient::Error) { NflTeamInfo.for(@other_team[:id]) }
      assert_not Rails.cache.exist?(NflTeamInfo.cache_key(@other_team[:id]))
    end
  end

  test "for is still cached just before 8 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamInfo.for(@team[:id])
      travel(7.hours + 59.minutes) { NflTeamInfo.for(@team[:id]) }
    end

    assert_equal 1, client.calls
  end

  test "for makes a fresh API call after 8 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamInfo.for(@team[:id])
      travel(8.hours + 1.minute) { NflTeamInfo.for(@team[:id]) }
    end

    assert_equal 2, client.calls
  end

  test "for serves the old details when the API fails after 8 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      old = NflTeamInfo.for(@team[:id])
      client.response = NflApiClient::Error.new("down")

      travel(8.hours + 1.minute) do
        assert_equal old, NflTeamInfo.for(@team[:id])
      end
    end
  end

  test "for serves the old details when the API sends another team after 8 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      old = NflTeamInfo.for(@team[:id])
      client.response = @raw.deep_merge("team" => { "id" => @other_team[:id] })

      travel(8.hours + 1.minute) do
        assert_equal old, NflTeamInfo.for(@team[:id])
      end
    end
  end

  test "for does not cache a failure, and pauses new calls for the cooldown" do
    client = FakeNflClient.new(NflApiClient::Error.new("boom"))

    with_world(client) do
      assert_raises(NflApiClient::Error) { NflTeamInfo.for(@team[:id]) }
      assert_raises(NflApiClient::Error) { NflTeamInfo.for(@team[:id]) } # cooling down: no call
      assert_equal 1, client.calls
      assert_not Rails.cache.exist?(NflTeamInfo.cache_key(@team[:id]))

      client.response = @raw
      travel(StaleCache::FAILURE_COOLDOWN + 1.second)
      assert_equal "3-8", NflTeamInfo.for(@team[:id])[:record][:total][:summary]
    end
  end
end
