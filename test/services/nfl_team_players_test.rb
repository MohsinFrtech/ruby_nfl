require "test_helper"

class NflTeamPlayersTest < ActiveSupport::TestCase
  setup do
    @raw = JSON.parse(file_fixture("team-players.json").binread)
    @teams = NflTeams.from_api(JSON.parse(file_fixture("nflteamlist.json").binread))
    @first_team, @second_team = @teams
  end

  # Runs the block with: a memory cache, a known list of teams, and a fake RapidAPI client.
  def with_world(client)
    with_memory_cache do
      NflTeams.stub(:all, @teams) do
        NflApiClient.stub(:new, client) { yield }
      end
    end
  end

  # --- from_api: shaping the data -------------------------------------------

  test "from_api turns each player into a small clean hash" do
    player = NflTeamPlayers.from_api(@raw).first

    assert_equal %i[first_name id last_name name short_name url], player.keys.sort
    assert_equal "4686911", player[:id]
    assert_equal "Jakorian Bennett", player[:name]
    assert_equal "Jakorian", player[:first_name]
    assert_equal "Bennett", player[:last_name]
    assert_equal "J. Bennett", player[:short_name]
    assert_equal "https://www.espn.com/nfl/player/_/id/4686911/jakorian-bennett", player[:url]
  end

  test "from_api keeps every player and the API's order" do
    players = NflTeamPlayers.from_api(@raw)

    assert_equal 4, players.size
    assert_equal %w[Bennett Brazzell Brooks Brown], players.map { |p| p[:last_name].split.first }
  end

  test "from_api keeps name suffixes like II" do
    player = NflTeamPlayers.from_api(@raw).find { |p| p[:id] == "5091739" }

    assert_equal "Chris Brazzell II", player[:name]
    assert_equal "Brazzell II", player[:last_name]
    assert_equal "C. Brazzell II", player[:short_name]
  end

  test "from_api does not copy the duplicate displayName" do
    assert_not_includes NflTeamPlayers.from_api(@raw).first.keys, :display_name
  end

  test "from_api returns an empty list for an unexpected response" do
    assert_equal [], NflTeamPlayers.from_api({ "message" => "oops" })
    assert_equal [], NflTeamPlayers.from_api({ "data" => nil })
    assert_equal [], NflTeamPlayers.from_api([])
    assert_equal [], NflTeamPlayers.from_api(nil)
  end

  test "from_api skips broken entries instead of crashing" do
    good_ids = NflTeamPlayers.from_api(@raw).map { |p| p[:id] }

    @raw["data"] << nil << "junk" << 42                       # not players at all
    @raw["data"] << { "fullName" => "No Id" }                  # no playerId
    @raw["data"] << { "playerId" => "", "fullName" => "Blank" } # blank playerId

    assert_equal good_ids, NflTeamPlayers.from_api(@raw).map { |p| p[:id] }
  end

  # --- for: one team, cached per team ---------------------------------------

  test "for returns fetched_at, the team's details and the players" do
    freeze_time do
      with_world(FakeNflClient.new(@raw)) do
        result = NflTeamPlayers.for(@first_team[:id])

        assert_equal Time.current.utc.iso8601, result[:fetched_at]
        assert_equal @first_team.slice(:id, :name, :abbreviation, :logo), result[:team]
        assert_equal 4, result[:players].size
      end
    end
  end

  test "for asks RapidAPI about the right team" do
    client = FakeNflClient.new(@raw)

    with_world(client) { NflTeamPlayers.for(@second_team[:id]) }

    assert_equal [ @second_team[:id] ], client.team_ids
  end

  test "for caches each team separately" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamPlayers.for(@first_team[:id])
      NflTeamPlayers.for(@first_team[:id])  # cache hit
      assert_equal 1, client.calls

      NflTeamPlayers.for(@second_team[:id]) # different team: its own call
      NflTeamPlayers.for(@second_team[:id]) # cache hit
      assert_equal 2, client.calls
    end
  end

  test "the players cache does not mix with the statistics cache" do
    assert_not_equal NflTeamPlayers.cache_key("22"), NflTeamStatistics.cache_key("22")
  end

  test "for refuses an unknown team without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      [ "99999", "abc", "", nil, "022" ].each do |bad_id|
        assert_raises(NflTeams::UnknownTeam, "expected #{bad_id.inspect} to be refused") do
          NflTeamPlayers.for(bad_id)
        end
        assert_not Rails.cache.exist?(NflTeamPlayers.cache_key(bad_id))
      end
    end

    assert_equal 0, client.calls
  end

  test "for is still cached just before 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamPlayers.for(@first_team[:id])
      travel(23.hours + 59.minutes) { NflTeamPlayers.for(@first_team[:id]) }
    end

    assert_equal 1, client.calls
  end

  test "for makes a fresh API call after 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamPlayers.for(@first_team[:id])
      travel(24.hours + 1.minute) { NflTeamPlayers.for(@first_team[:id]) }
    end

    assert_equal 2, client.calls
  end

  test "for serves the old roster when the API fails after 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      old = NflTeamPlayers.for(@first_team[:id])
      client.response = NflApiClient::Error.new("down") # RapidAPI goes down

      travel(24.hours + 1.minute) do
        assert_equal old, NflTeamPlayers.for(@first_team[:id])
      end
    end
  end
end
