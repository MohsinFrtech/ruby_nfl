require "test_helper"

class NflGameSummaryTest < ActiveSupport::TestCase
  # The fixture is a real answer for game 401872926: Week 1 of 2026, Arizona Cardinals at
  # Los Angeles Chargers, final 26-14. Play-by-play, win probability and standings were
  # trimmed out of it (we do not use them).
  GAME_ID = "401872926".freeze
  KICKOFF = Time.utc(2026, 9, 13, 20, 25)

  setup do
    @raw = JSON.parse(file_fixture("game-summary.json").binread)
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  def summary(raw = @raw) = NflGameSummary.from_api(raw)

  # Turns the finished game back into one that has not started (or is on, with state "in").
  def set_state!(state)
    competition = @raw["header"]["competitions"].first
    competition["status"]["type"].merge!("state" => state, "completed" => false)
  end

  def use_up_budget!
    Rails.cache.write(NflGameSummary.budget_key, NflGameSummary::DAILY_LOOKUPS, expires_in: 2.days)
  end

  # --- from_api: shaping the data -------------------------------------------

  test "from_api returns every part of the game" do
    assert_equal %i[broadcasts date id leaders officials player_stats scoring_plays season status
                    team_stats teams venue week], summary.keys.sort
    assert_equal GAME_ID, summary[:id]
    assert_equal 2026, summary[:season]
    assert_equal 1, summary[:week]
    assert_equal({ state: "post", detail: "Final", completed: true }, summary[:status])
    assert_equal [ "CBS" ], summary[:broadcasts]
    assert_equal({ name: "SoFi Stadium", city: "Inglewood", state: "CA", attendance: 70540 }, summary[:venue])
  end

  test "from_api gives both teams with their score, the winner and the score by quarter" do
    home, away = summary[:teams]

    assert_equal [ "LAC", "home", 14, false, [ 7, 0, 7, 0 ] ],
                 home.values_at(:abbreviation, :home_away, :score, :winner, :quarters)
    assert_equal [ "ARI", "away", 26, true, [ 7, 6, 3, 10 ] ],
                 away.values_at(:abbreviation, :home_away, :score, :winner, :quarters)
    assert_equal "1-0", away[:record]
    assert_equal away[:score], away[:quarters].sum
  end

  test "from_api gives each team's box score as name, label and text value" do
    stats = summary[:team_stats].first[:stats].index_by { |s| s[:name] }

    assert_equal({ name: "totalYards", label: "Total Yards", value: "393" }, stats["totalYards"])
    assert_equal "37:31", stats["possessionTime"][:value]
  end

  test "from_api lines up each player's stats with the category's columns" do
    passing = summary[:player_stats].flat_map { |team| team[:categories] }
                                    .find { |c| c[:players].any? { |p| p[:name] == "Jacoby Brissett" } }

    assert_equal "passing", passing[:category]
    assert_equal({ name: "passingYards", label: "YDS" }, passing[:columns][1])
    brissett = passing[:players].find { |p| p[:name] == "Jacoby Brissett" }
    assert_equal "2578570", brissett[:id]
    assert_equal "27/37", brissett[:stats]["completions/passingAttempts"]
    assert_equal "277", brissett[:stats]["passingYards"]
  end

  test "from_api gives nil totals for a category nobody had stats in" do
    punt_returns = summary[:player_stats].flat_map { |team| team[:categories] }.find { |c| c[:category] == "puntReturns" }

    assert_equal [], punt_returns[:players]
    assert_nil punt_returns[:totals]
  end

  test "from_api gives the top player of each leader category" do
    leader = summary[:leaders].first[:leaders].first

    assert_equal "passingYards", leader[:category]
    assert_equal({ id: "4038941", name: "Justin Herbert", position: "QB" }, leader[:player])
    assert_equal "17/27, 209 YDS, 1 TD, 1 INT", leader[:summary]
  end

  test "from_api gives the scoring plays in order, ending at the final score" do
    plays = summary[:scoring_plays]

    assert_equal 8, plays.size
    assert_equal({ quarter: 1, clock: "8:49", team: "ARI", type: "Rushing Touchdown",
                   text: "Jeremiyah Love 5 Yd Rush (Chad Ryland Kick)", away_score: 7, home_score: 0 }, plays.first)
    assert_equal [ 26, 14 ], plays.last.values_at(:away_score, :home_score)
  end

  test "from_api gives the officials" do
    assert_equal 7, summary[:officials].size
    assert_includes summary[:officials], { name: "Barry Anderson", position: "Umpire" }
  end

  test "from_api leaves out the play-by-play, win probability and standings" do
    json = summary.to_json

    assert_not_includes json, "homeWinPercentage"
    assert_not_includes json, "fullViewLink"
    assert_operator json.bytesize, :<, 40_000
  end

  test "from_api gives empty parts for an unexpected response" do
    [ { "message" => "oops" }, nil, [], { "header" => "junk" } ].each do |raw|
      result = summary(raw)

      assert_nil result[:id], "for #{raw.inspect}"
      assert_nil result[:venue]
      assert_equal [], result[:teams]
      assert_equal [], result[:player_stats]
      assert_equal [], result[:scoring_plays]
    end
  end

  test "from_api skips broken entries and treats broken pieces as missing" do
    competitors = @raw["header"]["competitions"].first["competitors"]
    competitors << nil << "junk"
    competitors.first["linescores"] << nil
    competitors.first["score"] = "fourteen"
    @raw["boxScore"]["players"].first["statistics"] << nil << 42
    @raw["boxScore"]["players"].first["statistics"].first["athletes"] << nil << "junk"
    @raw["leaders"] << nil
    @raw["leaders"].first["leaders"] << nil << { "name" => "empty", "leaders" => [] }
    @raw["scoringPlays"] << nil << "junk"
    @raw["scoringPlays"].first["period"] = "junk"
    @raw["gameInfo"]["officials"] << nil
    @raw["gameInfo"]["venue"]["address"] = "junk"

    result = nil
    assert_nothing_raised { result = summary }
    assert_equal 2, result[:teams].size
    assert_nil result[:teams].first[:score] # "fourteen" is not a number
    assert_equal 2, result[:leaders].size
    assert_equal 5, result[:leaders].first[:leaders].size
    assert_equal 8, result[:scoring_plays].size
    assert_nil result[:scoring_plays].first[:quarter]
    assert_equal 7, result[:officials].size
    assert_nil result[:venue][:city]
  end

  test "from_api handles a game with no box score yet" do
    set_state!("pre")
    @raw.delete("boxScore")
    @raw.delete("leaders")
    @raw.delete("scoringPlays")

    result = summary
    assert_equal "pre", result[:status][:state]
    assert_equal [], result[:team_stats]
    assert_equal [], result[:leaders]
    assert_equal [], result[:scoring_plays]
  end

  # --- cache lifetime -------------------------------------------------------

  test "fresh_for is 30 days for a finished game" do
    assert_equal 30.days, NflGameSummary.fresh_for(summary, KICKOFF + 1.day)
  end

  test "fresh_for waits until kickoff for a game that has not started, at most 8 hours" do
    set_state!("pre")

    assert_equal 8.hours, NflGameSummary.fresh_for(summary, KICKOFF - 2.days)
    assert_equal 30.minutes, NflGameSummary.fresh_for(summary, KICKOFF - 30.minutes)
    assert_equal 2.minutes, NflGameSummary.fresh_for(summary, KICKOFF - 30.seconds)
  end

  test "fresh_for is 5 minutes while the game is on, even if the API still says pre" do
    set_state!("pre")
    assert_equal 5.minutes, NflGameSummary.fresh_for(summary, KICKOFF + 1.hour)

    set_state!("in")
    assert_equal 5.minutes, NflGameSummary.fresh_for(summary, KICKOFF + 1.hour)
  end

  test "fresh_for does not treat a game still pre 6 hours after kickoff as live" do
    set_state!("pre")

    assert_equal 8.hours, NflGameSummary.fresh_for(summary, KICKOFF + 6.hours + 1.minute)
  end

  # --- for: one game, cached ------------------------------------------------

  test "for returns fetched_at and the game, and asks RapidAPI for the right game" do
    client = FakeNflClient.new(@raw)

    freeze_time do
      with_world(client) do
        result = NflGameSummary.for(GAME_ID)

        assert_equal Time.current.utc.iso8601, result[:fetched_at]
        assert_equal 26, result[:teams].last[:score]
      end
    end

    assert_equal [ GAME_ID ], client.team_ids
  end

  test "for refuses a badly formed id without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      [ "abc", "", nil, "0", "007", "-5", "1e3", " 401872926", "401872926 ", "12345678901", "1; DROP" ].each do |bad|
        assert_raises(NflGameSummary::UnknownGame, "expected #{bad.inspect} to be refused") do
          NflGameSummary.for(bad)
        end
        assert_not Rails.cache.exist?(NflGameSummary.cache_key(bad))
      end
    end

    assert_equal 0, client.calls
  end

  test "for remembers an unknown game for an hour" do
    client = FakeNflClient.new(NflApiClient::NotFound.new("no such game"))

    with_world(client) do
      assert_raises(NflGameSummary::UnknownGame) { NflGameSummary.for("999999999") }
      assert_raises(NflGameSummary::UnknownGame) { NflGameSummary.for("999999999") } # remembered
      assert_equal 1, client.calls

      travel(NflGameSummary::MISSING_TTL + 1.minute) do
        assert_raises(NflGameSummary::UnknownGame) { NflGameSummary.for("999999999") }
      end
      assert_equal 2, client.calls
    end
  end

  test "for refuses an answer about another game and caches nothing" do
    with_world(FakeNflClient.new(@raw)) do
      assert_raises(NflApiClient::Error) { NflGameSummary.for("401872927") }
      assert_not Rails.cache.exist?(NflGameSummary.cache_key("401872927"))
    end
  end

  test "for keeps a finished game for 30 days" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflGameSummary.for(GAME_ID)
      travel(29.days) { NflGameSummary.for(GAME_ID) }
      assert_equal 1, client.calls

      travel(30.days + 1.minute) { NflGameSummary.for(GAME_ID) }
      assert_equal 2, client.calls
    end
  end

  test "for calls again after 5 minutes while the game is on" do
    set_state!("in")
    client = FakeNflClient.new(@raw)
    travel_to(KICKOFF + 1.hour)

    with_world(client) do
      NflGameSummary.for(GAME_ID)
      travel(4.minutes) { NflGameSummary.for(GAME_ID) }
      assert_equal 1, client.calls

      travel(5.minutes + 1.second) { NflGameSummary.for(GAME_ID) }
      assert_equal 2, client.calls
    end
  end

  test "for serves the old copy when the API fails" do
    set_state!("in")
    client = FakeNflClient.new(@raw)
    travel_to(KICKOFF + 1.hour)

    with_world(client) do
      old = NflGameSummary.for(GAME_ID)
      client.response = NflApiClient::Error.new("down")

      travel(5.minutes + 1.second) do
        assert_equal old, NflGameSummary.for(GAME_ID)
      end
    end
  end

  test "for does not cache a failure, and pauses new calls for the cooldown" do
    client = FakeNflClient.new(NflApiClient::Error.new("boom"))

    with_world(client) do
      assert_raises(NflApiClient::Error) { NflGameSummary.for(GAME_ID) }
      assert_raises(NflApiClient::Error) { NflGameSummary.for(GAME_ID) } # cooling down: no call
      assert_equal 1, client.calls
      assert_not Rails.cache.exist?(NflGameSummary.cache_key(GAME_ID))

      client.response = @raw
      travel(StaleCache::FAILURE_COOLDOWN + 1.second)
      assert_equal GAME_ID, NflGameSummary.for(GAME_ID)[:id]
    end
  end

  # --- daily budget of new lookups ------------------------------------------

  test "each real RapidAPI call counts against today's budget, cached answers do not" do
    with_world(FakeNflClient.new(@raw)) do
      NflGameSummary.for(GAME_ID)
      NflGameSummary.for(GAME_ID) # cache hit

      assert_equal 1, Rails.cache.read(NflGameSummary.budget_key)
    end
  end

  test "over the budget, a new game is refused without calling RapidAPI" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      use_up_budget!
      assert_raises(NflApiClient::BudgetExceeded) { NflGameSummary.for(GAME_ID) }
      assert_not Rails.cache.exist?(NflGameSummary.cache_key(GAME_ID) + ":failed") # no cooldown for this
    end

    assert_equal 0, client.calls
  end

  test "over the budget, a cached game is still served" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflGameSummary.for(GAME_ID)
      use_up_budget!

      assert_equal GAME_ID, NflGameSummary.for(GAME_ID)[:id]
    end

    assert_equal 1, client.calls
  end

  test "the budget starts again the next day (UTC)" do
    client = FakeNflClient.new(@raw)
    travel_to(Time.utc(2026, 11, 25, 23, 0))

    with_world(client) do
      use_up_budget!
      assert_raises(NflApiClient::BudgetExceeded) { NflGameSummary.for(GAME_ID) }

      travel(2.hours) { NflGameSummary.for(GAME_ID) }
    end

    assert_equal 1, client.calls
  end
end
