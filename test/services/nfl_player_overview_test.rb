require "test_helper"

class NflPlayerOverviewTest < ActiveSupport::TestCase
  PLAYER_ID = "4685720".freeze

  setup do
    @raw = JSON.parse(file_fixture("player-overview.json").binread)
    @rookie = JSON.parse(file_fixture("player-overview-rookie.json").binread)
  end

  def overview(raw = @raw)
    NflPlayerOverview.from_api(raw)
  end

  def section(name)
    @raw["player_overview"][name]
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  # --- statistics ------------------------------------------------------------

  test "statistics become columns once, plus one name => value row per split" do
    stats = overview[:statistics]

    assert_equal "2026 Passing", stats[:title]
    assert_equal 15, stats[:columns].size
    assert_equal [ "Regular Season", "Projected", "Last 5 Games", "Career" ], stats[:splits].map { |s| s[:split] }
    assert_equal "2,197", stats[:splits].first[:stats]["passingYards"] # text, exactly as the API gives it
  end

  test "statistics columns know their label and their group" do
    columns = overview[:statistics][:columns].index_by { |c| c[:name] }

    assert_equal({ label: "YDS", category: "passing" }, columns["passingYards"].slice(:label, :category))
    assert_equal({ label: "YDS", category: "rushing" }, columns["rushingYards"].slice(:label, :category))
  end

  test "two columns with the same label do not overwrite each other" do
    row = overview[:statistics][:splits].first[:stats]

    assert_not_equal row["passingYards"], row["rushingYards"] # both labelled "YDS" by the API
    assert_equal 15, row.size
  end

  # --- game log --------------------------------------------------------------

  test "game_log lists games newest first with opponent, result and score" do
    games = overview[:game_log]

    assert_equal [ 6, 4 ], games.map { |g| g[:week] }
    latest = games.first
    assert_equal "@", latest[:home_away]
    assert_equal "Philadelphia Eagles", latest[:opponent]
    assert_equal "W", latest[:result]
    assert_equal "25-14", latest[:score]
  end

  test "game_log attaches each game's stats by group" do
    latest = overview[:game_log].first

    assert_equal %w[passing rushing], latest[:stats].keys
    assert_equal "20", latest[:stats]["passing"]["completions"]
  end

  # --- next game -------------------------------------------------------------

  test "next_game has the date, venue, channel, teams and betting line" do
    game = overview[:next_game]

    assert_equal "Carolina Panthers at New Orleans Saints", game[:name]
    assert_equal "Caesars Superdome", game[:venue]
    assert_equal "Fox", game[:broadcast]
    assert_equal [ "home", "away" ], game[:teams].map { |t| t[:home_away] }
    assert_equal({ details: "NO -2.5", over_under: 48.5, spread: -2.5 }, game[:odds])
  end

  test "next_game has no odds when the API gives none" do
    section("nextGame")["league"]["events"].first["odds"] = {}

    assert_nil overview[:next_game][:odds]
  end

  # --- news ------------------------------------------------------------------

  test "news uses the same clean shape as GET /news, newest first" do
    news = overview[:news]

    assert_equal 3, news.size
    assert_equal NflNews.from_api(section("news")), news
    assert_equal news.map { |a| a[:published_at] }.sort.reverse, news.map { |a| a[:published_at] }
  end

  # --- fantasy, rotowire, awards --------------------------------------------

  test "fantasy numbers become real numbers" do
    fantasy = overview[:fantasy]

    assert_equal 313, fantasy[:draft_rank]
    assert_equal 11, fantasy[:position_rank]
    assert_equal 80.58, fantasy[:percent_owned]
    assert_equal 1.8, fantasy[:last_7_days]
    assert_kind_of String, fantasy[:projection]
  end

  test "fantasy turns text that is not a number into nil, and never reads 010 as octal" do
    section("fantasy").merge!("draftRank" => "n/a", "positionRank" => "010")

    fantasy = overview[:fantasy]
    assert_nil fantasy[:draft_rank]
    assert_equal 10, fantasy[:position_rank]
  end

  test "rotowire keeps the API's own date text" do
    assert_equal "Sun Nov 08 16:07:48 PST 2026", overview[:rotowire][:published]
  end

  test "awards list the name, how many times and the seasons" do
    award = overview[:awards].find { |a| a[:name] == "NFL MVP" }

    assert_equal({ name: "NFL MVP", count: "1x", seasons: [ "1984" ] }, award)
  end

  # --- sections come and go --------------------------------------------------

  test "a player with a full record gets every section" do
    assert_equal %i[awards fantasy game_log news next_game rotowire statistics], overview.keys.sort
  end

  test "a player without stats or a game log simply has no such sections" do
    result = overview(@rookie)

    assert_not result.key?(:statistics)
    assert_not result.key?(:game_log)
    assert_not result.key?(:awards)
    assert_equal %i[fantasy news next_game rotowire], result.keys.sort
  end

  test "an empty rotowire section is left out" do
    section("rotowire").clear

    assert_not overview.key?(:rotowire)
  end

  test "sections with unexpected content are left out instead of crashing" do
    @raw["player_overview"].merge!(
      "statistics" => "oops", "gameLog" => [], "nextGame" => nil,
      "news" => "oops", "fantasy" => [], "rotowire" => "oops", "awards" => nil
    )

    assert_equal({}, overview)
  end

  test "from_api returns an empty hash for an unexpected response" do
    [ nil, [], "oops", {}, { "message" => "oops" }, { "player_overview" => nil } ].each do |raw|
      assert_equal({}, NflPlayerOverview.from_api(raw), "expected #{raw.inspect} to give {}")
    end
  end

  # --- for: one player, cached per player -----------------------------------

  test "for returns fetched_at, the player id and the sections" do
    freeze_time do
      with_world(FakeNflClient.new(@raw)) do
        result = NflPlayerOverview.for(PLAYER_ID)

        assert_equal Time.current.utc.iso8601, result[:fetched_at]
        assert_equal PLAYER_ID, result[:player_id]
        assert_equal 3, result[:news].size
      end
    end
  end

  test "for asks RapidAPI about the right player, given as text or as a number" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflPlayerOverview.for(PLAYER_ID)
      NflPlayerOverview.for(1)
    end

    assert_equal [ PLAYER_ID, "1" ], client.team_ids # (the fake records whatever id it was given)
  end

  test "for caches each player separately" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflPlayerOverview.for(PLAYER_ID)
      NflPlayerOverview.for(PLAYER_ID) # cache hit
      assert_equal 1, client.calls

      NflPlayerOverview.for("1")       # different player: its own call
      NflPlayerOverview.for("1")       # cache hit
      assert_equal 2, client.calls
    end
  end

  test "for refuses a badly formed id without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)
    bad_ids = [ "abc", "", nil, "0", "007", "1e3", " 1", "1 ", "1\n", "-5", "1.5", "12345678901",
                "1; DROP TABLE", "٣", "1/../2" ]

    with_world(client) do
      bad_ids.each do |bad_id|
        assert_raises(NflPlayerOverview::UnknownPlayer, "expected #{bad_id.inspect} to be refused") do
          NflPlayerOverview.for(bad_id)
        end
        assert_not Rails.cache.exist?(NflPlayerOverview.cache_key(bad_id))
      end
    end

    assert_equal 0, client.calls
  end

  test "for accepts ids of 1 to 10 digits" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      %w[1 4685720 9999999999].each { |id| assert_nothing_raised { NflPlayerOverview.for(id) } }
    end

    assert_equal 3, client.calls
  end

  test "the cache keys of different kinds never collide" do
    keys = [ NflPlayerOverview.cache_key("1"), NflPlayerOverview.missing_key("1"),
             NflTeamPlayers.cache_key("1"), NflTeamStatistics.cache_key("1") ]

    assert_equal keys.size, keys.uniq.size
  end

  test "for is still cached just before 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflPlayerOverview.for(PLAYER_ID)
      travel(23.hours + 59.minutes) { NflPlayerOverview.for(PLAYER_ID) }
    end

    assert_equal 1, client.calls
  end

  test "for makes a fresh API call after 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflPlayerOverview.for(PLAYER_ID)
      travel(24.hours + 1.minute) { NflPlayerOverview.for(PLAYER_ID) }
    end

    assert_equal 2, client.calls
  end

  # --- daily budget of new lookups ------------------------------------------

  def use_up_budget!
    Rails.cache.write(NflPlayerOverview.budget_key, NflPlayerOverview::DAILY_LOOKUPS, expires_in: 2.days)
  end

  test "each real RapidAPI call counts against today's budget, cached answers do not" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflPlayerOverview.for(PLAYER_ID)
      NflPlayerOverview.for(PLAYER_ID) # from the cache
      assert_equal 1, Rails.cache.read(NflPlayerOverview.budget_key)
    end
  end

  test "over the budget, a new player is refused without calling RapidAPI" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      use_up_budget!
      assert_raises(NflApiClient::BudgetExceeded) { NflPlayerOverview.for(PLAYER_ID) }
      assert_equal 0, client.calls
      assert_not Rails.cache.exist?(NflPlayerOverview.missing_key(PLAYER_ID)) # not remembered as unknown
    end
  end

  test "over the budget, a cached player is still served, and so is an expired one's backup" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      old = NflPlayerOverview.for(PLAYER_ID)
      use_up_budget!
      assert_equal old, NflPlayerOverview.for(PLAYER_ID)

      travel(24.hours + 1.minute) do
        use_up_budget! # the new day's budget is used up too
        assert_equal old, NflPlayerOverview.for(PLAYER_ID)
      end
      assert_equal 1, client.calls
    end
  end

  test "the budget starts again the next day (UTC)" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      travel_to(Time.utc(2026, 11, 25, 23, 0))
      use_up_budget!
      assert_raises(NflApiClient::BudgetExceeded) { NflPlayerOverview.for(PLAYER_ID) }

      travel_to(Time.utc(2026, 11, 26, 0, 1))
      assert_nothing_raised { NflPlayerOverview.for(PLAYER_ID) }
      assert_equal 1, client.calls
    end
  end

  # --- broken data -------------------------------------------------------------

  test "broken entries are treated as missing instead of crashing" do
    overview_raw = @raw["player_overview"]
    overview_raw["statistics"]["splits"] << nil << "junk"
    overview_raw["statistics"]["categories"] << nil
    overview_raw["gameLog"]["events"]["999"] = nil
    overview_raw["gameLog"]["events"].each_value { |e| e["opponent"] = "junk" if e.is_a?(Hash) }
    overview_raw["gameLog"]["statistics"] << nil
    overview_raw["gameLog"]["statistics"].each { |t| t["events"]&.unshift(nil) if t.is_a?(Hash) }
    overview_raw["nextGame"]["league"]["events"].first["competitors"] << nil
    overview_raw["awards"] << nil << "junk"

    result = overview
    assert_equal 4, result[:statistics][:splits].size
    assert result[:game_log].any?
    assert result[:game_log].all? { |game| game[:opponent].nil? }
    assert result[:game_log].any? { |game| game[:stats].any? } # real stat rows are still matched
    assert_equal 2, result[:next_game][:teams].size
    assert result[:awards].all? { |award| award[:name].present? }
  end

  test "for serves the old overview when the API fails after 24 hours" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      old = NflPlayerOverview.for(PLAYER_ID)
      client.response = NflApiClient::Error.new("down")

      travel(24.hours + 1.minute) do
        assert_equal old, NflPlayerOverview.for(PLAYER_ID)
      end
    end
  end

  # --- unknown players -------------------------------------------------------

  test "for turns the API's not-found into UnknownPlayer and caches nothing for the player" do
    client = FakeNflClient.new(NflApiClient::NotFound.new("not found"))

    with_world(client) do
      assert_raises(NflPlayerOverview::UnknownPlayer) { NflPlayerOverview.for("123456") }

      assert_not Rails.cache.exist?(NflPlayerOverview.cache_key("123456"))
    end
  end

  test "for remembers an unknown player for an hour, so a fake id is not retried" do
    client = FakeNflClient.new(NflApiClient::NotFound.new("not found"))

    with_world(client) do
      2.times { assert_raises(NflPlayerOverview::UnknownPlayer) { NflPlayerOverview.for("123456") } }
      assert_equal 1, client.calls # the second request never reached the API

      travel(1.hour + 1.minute) do
        assert_raises(NflPlayerOverview::UnknownPlayer) { NflPlayerOverview.for("123456") }
      end
      assert_equal 2, client.calls # an hour later it asks again
    end
  end

  test "an ordinary API failure is a 502-type error and is not remembered as unknown" do
    client = FakeNflClient.new(NflApiClient::Error.new("down"))

    with_world(client) do
      2.times do
        error = assert_raises(NflApiClient::Error) { NflPlayerOverview.for(PLAYER_ID) }
        assert_instance_of NflApiClient::Error, error # not NotFound, not UnknownPlayer
        travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown, then try again
      end
      assert_equal 2, client.calls
    end
  end
end
