require "test_helper"

class NflTeamStatisticsTest < ActiveSupport::TestCase
  setup do
    @raw = JSON.parse(file_fixture("team-statistic.json").binread)
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

  def stat(side, category, name)
    NflTeamStatistics.from_api(@raw)[side].find { |c| c[:category] == category }[:stats].find { |s| s[:name] == name }
  end

  # --- from_api: shaping the data -------------------------------------------

  test "from_api returns the team's own stats and the opponent stats, grouped by category" do
    result = NflTeamStatistics.from_api(@raw)

    assert_equal %i[opponent_stats team_stats], result.keys.sort
    assert_equal %w[passing miscellaneous], result[:team_stats].map { |c| c[:category] }
    assert_equal %w[passing miscellaneous], result[:opponent_stats].map { |c| c[:category] }
    assert_equal "Passing", result[:team_stats].first[:label]
  end

  test "from_api gives each own stat a small clean shape, without a rank" do
    completion = stat(:team_stats, "passing", "completionPct")

    assert_equal %i[abbreviation display label name per_game value], completion.keys.sort
    assert_equal "Completion Percentage", completion[:label]
    assert_equal "CMP%", completion[:abbreviation]
    assert_equal 60.1, completion[:value]
    assert_equal "60.1", completion[:display]
  end

  test "from_api adds rank and rank_label only on the opponent side" do
    completion = stat(:opponent_stats, "passing", "completionPct")

    assert_equal %i[abbreviation display label name per_game rank rank_label value], completion.keys.sort
    assert_equal 26, completion[:rank]
    assert_equal "26th", completion[:rank_label]
  end

  test "from_api keeps tied rank text such as Tied-9th" do
    @raw["opponent"].first["stats"].first.merge!("rank" => 9, "rankDisplayValue" => "Tied-9th")

    completion = stat(:opponent_stats, "passing", "completionPct")
    assert_equal 9, completion[:rank]
    assert_equal "Tied-9th", completion[:rank_label]
  end

  test "from_api rounds per_game to 3 decimals" do
    assert_equal 59.939, stat(:team_stats, "passing", "completionPct")[:per_game]
  end

  test "from_api keeps nil for a stat the API gave no numbers for" do
    third_down = stat(:opponent_stats, "miscellaneous", "thirdDownEff")

    assert_nil third_down[:value]
    assert_nil third_down[:per_game]
    assert_nil third_down[:rank]
    assert_not_nil third_down[:display] # the text version is still there
  end

  test "from_api does not copy the long, repeated descriptions" do
    assert_not_includes NflTeamStatistics.from_api(@raw).to_json, "The percentage of completed passes"
  end

  test "from_api returns empty lists for an unexpected response" do
    empty = { team_stats: [], opponent_stats: [] }

    assert_equal empty, NflTeamStatistics.from_api({ "message" => "oops" })
    assert_equal empty, NflTeamStatistics.from_api(nil)
    assert_equal empty, NflTeamStatistics.from_api([])
  end

  test "from_api skips broken categories and stats instead of crashing" do
    categories = @raw.dig("stats", "categories")
    categories << nil << "junk"                                  # not categories at all
    categories.first["stats"] << nil << 42                       # not stats at all
    categories.first["stats"].first["perGameValue"] = "59.9"     # text instead of a number

    result = NflTeamStatistics.from_api(@raw)
    passing = result[:team_stats].find { |c| c[:category] == "passing" }

    assert_equal %w[passing miscellaneous], result[:team_stats].map { |c| c[:category] }
    assert_equal %w[completionPct completions interceptionPct], passing[:stats].map { |s| s[:name] }
    assert_nil passing[:stats].first[:per_game]
  end

  # --- for: one team, cached per team ---------------------------------------

  test "for returns fetched_at, the team's details and both sets of stats" do
    freeze_time do
      with_world(FakeNflClient.new(@raw)) do
        result = NflTeamStatistics.for(@first_team[:id])

        assert_equal Time.current.utc.iso8601, result[:fetched_at]
        assert_equal @first_team.slice(:id, :name, :abbreviation, :logo), result[:team]
        assert_equal 2, result[:team_stats].size
        assert_equal 2, result[:opponent_stats].size
      end
    end
  end

  test "for asks RapidAPI about the right team" do
    client = FakeNflClient.new(@raw)

    with_world(client) { NflTeamStatistics.for(@second_team[:id]) }

    assert_equal [ @second_team[:id] ], client.team_ids
  end

  test "for accepts a number as well as text" do
    client = FakeNflClient.new(@raw)

    with_world(client) { NflTeamStatistics.for(@first_team[:id].to_i) }

    assert_equal [ @first_team[:id] ], client.team_ids
  end

  test "for caches each team separately" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamStatistics.for(@first_team[:id])
      NflTeamStatistics.for(@first_team[:id])  # cache hit
      assert_equal 1, client.calls

      NflTeamStatistics.for(@second_team[:id]) # different team: its own call
      NflTeamStatistics.for(@second_team[:id]) # cache hit
      assert_equal 2, client.calls
    end
  end

  test "for refuses an unknown team without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      [ "99999", "abc", "", nil, "0", "1; DROP TABLE", "022" ].each do |bad_id|
        assert_raises(NflTeams::UnknownTeam, "expected #{bad_id.inspect} to be refused") do
          NflTeamStatistics.for(bad_id)
        end
        assert_not Rails.cache.exist?(NflTeamStatistics.cache_key(bad_id))
      end
    end

    assert_equal 0, client.calls
  end

  test "for is still cached just before 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamStatistics.for(@first_team[:id])
      travel(23.hours + 59.minutes) { NflTeamStatistics.for(@first_team[:id]) }
    end

    assert_equal 1, client.calls
  end

  test "for makes a fresh API call after 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamStatistics.for(@first_team[:id])
      travel(24.hours + 1.minute) { NflTeamStatistics.for(@first_team[:id]) }
    end

    assert_equal 2, client.calls
  end

  test "for serves the old stats when the API fails after 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      old = NflTeamStatistics.for(@first_team[:id])
      client.response = NflApiClient::Error.new("down") # RapidAPI goes down

      travel(24.hours + 1.minute) do
        assert_equal old, NflTeamStatistics.for(@first_team[:id])
      end
    end
  end

  test "the backup is per team: another team has no backup to fall back on" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflTeamStatistics.for(@first_team[:id])
      client.response = NflApiClient::Error.new("down") # RapidAPI goes down

      travel(24.hours + 1.minute) do
        assert_raises(NflApiClient::Error) { NflTeamStatistics.for(@second_team[:id]) }
      end
    end
  end
end
