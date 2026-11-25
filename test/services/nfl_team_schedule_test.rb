require "test_helper"

class NflTeamScheduleTest < ActiveSupport::TestCase
  # The fixture is a real answer for team 22 (Arizona Cardinals), season 2026, fetched on
  # 25 Nov 2026: weeks 1-11 are over (3-8), week 12 is next (Sun 29 Nov 21:25 UTC), bye in week 14.
  NOW = Time.utc(2026, 11, 25, 9)
  NEXT_KICKOFF = Time.utc(2026, 11, 29, 21, 25)

  setup do
    @raw = JSON.parse(file_fixture("team-schedule.json").binread)
    @teams = NflTeams.from_api(JSON.parse(file_fixture("nflteamlist.json").binread))
    @team = @teams.find { |t| t[:id] == "22" }
    @other_team = @teams.find { |t| t[:id] != "22" }
  end

  def with_world(client)
    with_memory_cache do
      NflTeams.stub(:all, @teams) do
        NflApiClient.stub(:new, client) { yield }
      end
    end
  end

  def schedule = NflTeamSchedule.from_api(@raw)
  def game(week) = schedule[:games].find { |g| g[:week] == week }

  # Every game marked finished, as at the end of the season.
  def finish_every_game!
    @raw["events"].each do |event|
      competition = event["competitions"].first
      competition["status"]["type"].merge!("state" => "post", "completed" => true)
      competition["competitors"].each_with_index do |c, i|
        c["score"] = { "value" => 10 + i }
        c["winner"] = i == 1
      end
    end
  end

  # --- from_api: shaping the data -------------------------------------------

  test "from_api returns the season, the team, the bye week and the games" do
    result = schedule

    assert_equal %i[bye_week games season season_type team], result.keys.sort
    assert_equal 2026, result[:season]
    assert_equal "Regular Season", result[:season_type]
    assert_equal 14, result[:bye_week]
    assert_equal "Arizona Cardinals", result[:team][:name]
    assert_equal "3-8", result[:team][:record]
    assert_equal "#a40227", result[:team][:color]
  end

  test "from_api lists the 17 games in date order, with no game in the bye week" do
    games = schedule[:games]

    assert_equal 17, games.size
    assert_equal games.map { |g| g[:date] }.sort, games.map { |g| g[:date] }
    assert_not_includes games.map { |g| g[:week] }, 14
  end

  test "from_api shows each game from the team's side" do
    away_win = game(1)

    assert_equal "away", away_win[:home_away]
    assert_equal "LAC", away_win[:opponent][:abbreviation]
    assert_equal 26, away_win[:score]
    assert_equal 14, away_win[:opponent_score]
    assert_equal "W", away_win[:result]

    home_loss = game(2)
    assert_equal "home", home_loss[:home_away]
    assert_equal "SEA", home_loss[:opponent][:abbreviation]
    assert_equal [ 7, 31, "L" ], home_loss.values_at(:score, :opponent_score, :result)
  end

  test "from_api results add up to the team's record" do
    results = schedule[:games].map { |g| g[:result] }.compact.tally

    assert_equal({ "W" => 3, "L" => 8 }, results)
  end

  test "from_api gives no score or result for a game that has not been played" do
    upcoming = game(12)

    assert_equal "pre", upcoming[:status]
    assert_nil upcoming[:score]
    assert_nil upcoming[:opponent_score]
    assert_nil upcoming[:result]
    assert_equal [ "Fox" ], upcoming[:broadcasts]
  end

  test "from_api gives T for a finished game nobody won" do
    competition = @raw["events"].first["competitions"].first
    competition["competitors"].each { |c| c.merge!("winner" => false, "score" => { "value" => 20 }) }

    assert_equal "T", game(1)[:result]
  end

  test "from_api does not copy the logos and links of every game" do
    assert_not_includes schedule.to_json, "Gamecast"
    assert_operator schedule.to_json.bytesize, :<, 12_000
  end

  test "from_api gives empty parts for an unexpected response" do
    [ { "message" => "oops" }, nil, [], { "team" => "junk", "events" => "junk" } ].each do |raw|
      result = NflTeamSchedule.from_api(raw)

      assert_nil result[:team][:id], "for #{raw.inspect}"
      assert_nil result[:season]
      assert_equal [], result[:games]
    end
  end

  test "from_api skips broken games and treats broken pieces as missing" do
    good = schedule[:games].size
    @raw["events"] << nil << "junk" << 42
    competition = @raw["events"].first["competitions"].first
    competition["competitors"] << nil << "junk"
    competition["broadcasts"] << nil << { "media" => "junk" }
    competition["venue"] = "junk"
    competition["competitors"].first["score"] = { "value" => "fourteen" }

    result = nil
    assert_nothing_raised { result = NflTeamSchedule.from_api(@raw) }
    assert_equal good, result[:games].size

    first = result[:games].first
    assert_equal "LAC", first[:opponent][:abbreviation]
    assert_nil first[:venue]
    assert_nil first[:opponent_score] # "fourteen" is not a number
    assert_nil first[:result]         # so the result is not known either
    assert_equal [ "CBS" ], first[:broadcasts]
  end

  # --- the current season ---------------------------------------------------

  test "current_season is this year from March, and last year in January and February" do
    assert_equal 2026, NflTeamSchedule.current_season(Time.utc(2026, 11, 25))
    assert_equal 2026, NflTeamSchedule.current_season(Time.utc(2026, 3, 1))
    assert_equal 2025, NflTeamSchedule.current_season(Time.utc(2026, 2, 10)) # Super Bowl time
    assert_equal 2025, NflTeamSchedule.current_season(Time.utc(2026, 1, 1))
  end

  # --- cache lifetime -------------------------------------------------------

  test "fresh_for waits until the next kickoff, at most 8 hours" do
    games = schedule[:games]

    assert_equal 8.hours, NflTeamSchedule.fresh_for(games, NOW)
    assert_equal 30.minutes, NflTeamSchedule.fresh_for(games, NEXT_KICKOFF - 30.minutes)
    assert_equal 2.minutes, NflTeamSchedule.fresh_for(games, NEXT_KICKOFF - 30.seconds)
  end

  test "fresh_for is 15 minutes while a game is on, even if the API still says pre" do
    games = schedule[:games]

    assert_equal 15.minutes, NflTeamSchedule.fresh_for(games, NEXT_KICKOFF + 1.hour) # still "pre"
    games.find { |g| g[:week] == 12 }[:status] = "in"
    assert_equal 15.minutes, NflTeamSchedule.fresh_for(games, NEXT_KICKOFF + 1.hour)
  end

  test "fresh_for does not treat a game still pre 6 hours after kickoff as live" do
    games = schedule[:games]

    assert_equal 8.hours, NflTeamSchedule.fresh_for(games, NEXT_KICKOFF + 6.hours + 1.minute)
  end

  test "fresh_for is 7 days when every game is over" do
    finish_every_game!

    assert_equal 7.days, NflTeamSchedule.fresh_for(schedule[:games], NOW)
  end

  # --- for: one team and season, cached -------------------------------------

  test "for returns fetched_at and the schedule, for the current season by default" do
    client = FakeNflClient.new(@raw)

    travel_to(NOW) do
      with_world(client) do
        result = NflTeamSchedule.for(@team[:id])

        assert_equal NOW.iso8601, result[:fetched_at]
        assert_equal 17, result[:games].size
      end
    end

    assert_equal [ [ "22", "2026" ] ], client.team_seasons
  end

  test "for treats an empty season as the current season" do
    client = FakeNflClient.new(@raw)

    travel_to(NOW) { with_world(client) { NflTeamSchedule.for(@team[:id], "") } }

    assert_equal [ [ "22", "2026" ] ], client.team_seasons
  end

  test "for asks for the chosen season, and caches each team and season separately" do
    old_season = @raw.deep_merge("requestedSeason" => { "year" => 2020 })
    client = FakeNflClient.new(old_season)

    travel_to(NOW) do
      with_world(client) do
        NflTeamSchedule.for(@team[:id], "2020")
        NflTeamSchedule.for(@team[:id], 2020) # cache hit (a number works too)
        assert_equal 1, client.calls

        client.response = @raw
        NflTeamSchedule.for(@team[:id], "2026") # another season: its own call
        assert_equal 2, client.calls
      end
    end

    assert_equal [ %w[22 2020], %w[22 2026] ], client.team_seasons
  end

  test "for refuses an unknown team without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      [ "99999", "abc", "", nil, "022" ].each do |bad_id|
        assert_raises(NflTeams::UnknownTeam, "expected #{bad_id.inspect} to be refused") do
          NflTeamSchedule.for(bad_id, "2026")
        end
      end
    end

    assert_equal 0, client.calls
  end

  test "for refuses a bad or future season without calling RapidAPI or caching anything" do
    client = FakeNflClient.new(@raw)

    travel_to(NOW) do
      with_world(client) do
        [ "2001", "2027", "1999", "abc", "26", "02026", " 2026", "2026.0", "2026; x" ].each do |bad|
          assert_raises(NflTeamSchedule::UnknownSeason, "expected #{bad.inspect} to be refused") do
            NflTeamSchedule.for(@team[:id], bad)
          end
          assert_not Rails.cache.exist?(NflTeamSchedule.cache_key(@team[:id], bad))
        end
      end
    end

    assert_equal 0, client.calls
  end

  test "for refuses an answer about another team or another season, and caches nothing" do
    travel_to(NOW) do
      [ [ @other_team[:id], "2026" ], [ @team[:id], "2025" ] ].each do |team_id, season|
        with_world(FakeNflClient.new(@raw)) do
          assert_raises(NflApiClient::Error) { NflTeamSchedule.for(team_id, season) }
          assert_not Rails.cache.exist?(NflTeamSchedule.cache_key(team_id, season))
        end
      end
    end
  end

  test "for refuses an answer whose games are all broken" do
    @raw["events"] = [ nil, "junk" ]

    travel_to(NOW) do
      with_world(FakeNflClient.new(@raw)) do
        assert_raises(NflApiClient::Error) { NflTeamSchedule.for(@team[:id]) }
        assert_not Rails.cache.exist?(NflTeamSchedule.cache_key(@team[:id], "2026"))
      end
    end
  end

  test "for is cached until the next refresh, then calls again" do
    client = FakeNflClient.new(@raw)
    travel_to(NOW) # (no block: Rails does not allow a travel block inside another one)

    with_world(client) do
      NflTeamSchedule.for(@team[:id])
      travel(7.hours + 59.minutes) { NflTeamSchedule.for(@team[:id]) }
      assert_equal 1, client.calls

      travel(8.hours + 1.minute) { NflTeamSchedule.for(@team[:id]) }
      assert_equal 2, client.calls
    end
  end

  test "for serves the old schedule when the API fails" do
    client = FakeNflClient.new(@raw)
    travel_to(NOW)

    with_world(client) do
      old = NflTeamSchedule.for(@team[:id])
      client.response = NflApiClient::Error.new("down")

      travel(8.hours + 1.minute) do
        assert_equal old, NflTeamSchedule.for(@team[:id])
      end
    end
  end

  test "for does not cache a failure, and pauses new calls for the cooldown" do
    client = FakeNflClient.new(NflApiClient::Error.new("boom"))

    travel_to(NOW) do
      with_world(client) do
        assert_raises(NflApiClient::Error) { NflTeamSchedule.for(@team[:id]) }
        assert_raises(NflApiClient::Error) { NflTeamSchedule.for(@team[:id]) } # cooling down: no call
        assert_equal 1, client.calls

        client.response = @raw
        travel(StaleCache::FAILURE_COOLDOWN + 1.second)
        assert_equal 17, NflTeamSchedule.for(@team[:id])[:games].size
      end
    end
  end
end
