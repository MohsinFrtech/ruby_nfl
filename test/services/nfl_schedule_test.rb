require "test_helper"

class NflScheduleTest < ActiveSupport::TestCase
  # Saturday morning, before the Sunday games. Kickoffs in the fixture (UTC):
  #   WSH @ NYG  Fri 13 Nov 01:15  (Final)
  #   NE VS DET  Sun 15 Nov 14:30  (Munich)
  #   KC @ ATL   Sun 15 Nov 18:00
  #   PIT @ CIN  Mon 16 Nov 01:20  (still Sunday night in the US)
  BASE = Time.utc(2026, 11, 14, 9)

  # A fake RapidAPI for the chosen-week question: it returns the fixture's games, labelled
  # with the year and week it was ASKED for, like the real API does. It also remembers the
  # questions, and can be told to fail.
  class EchoClient
    attr_reader :calls, :asked
    attr_writer :failure

    def initialize(raw)
      @raw = raw
      @calls = 0
      @asked = []
    end

    def schedule_for(year, week)
      @calls += 1
      @asked << [ year, week ]
      raise @failure if @failure

      copy = JSON.parse(JSON.generate(@raw))
      copy.each_value do |day|
        day["games"].each do |game|
          game["week"]["number"] = week.to_i
          game["season"]["year"] = year.to_i
        end
      end
      copy
    end
  end

  setup do
    @raw = JSON.parse(file_fixture("nflschedule.json").binread)
  end

  def games_raw = @raw.values.flat_map { |day| day["games"] }

  def game_raw(short_name) = games_raw.find { |g| g["shortName"] == short_name }

  def set_status(short_name, state:, completed:, description: state)
    game_raw(short_name)["status"]["type"].merge!(
      "state" => state, "completed" => completed, "description" => description
    )
  end

  def finish_all!
    games_raw.each { |g| g["status"]["type"].merge!("state" => "post", "completed" => true, "description" => "Final") }
  end

  def schedule(raw = @raw) = NflSchedule.from_api(raw)

  def game(short_name) = schedule[:games].find { |g| g[:short_name] == short_name }

  def fresh_for_at(now) = NflSchedule.fresh_for(schedule[:games], now)

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  # --- from_api: the season, week and order ---------------------------------

  test "from_api reads the season and the week from the games" do
    result = schedule

    assert_equal 2026, result[:year]
    assert_equal "regular-season", result[:season_type]
    assert_equal 10, result[:week]
  end

  test "from_api puts all games in one list sorted by kickoff, whatever order the API sends" do
    assert_equal [ "WSH @ NYG", "NE VS DET", "KC @ ATL", "PIT @ CIN" ], schedule[:games].map { |g| g[:short_name] }
  end

  test "from_api gives the exact kickoff in UTC and the US day the game belongs to" do
    sunday_night = game("PIT @ CIN")

    assert_equal "2026-11-16T01:20:00Z", sunday_night[:date]
    assert_equal "2026-11-15", sunday_night[:day] # still Sunday in the US
  end

  # --- from_api: one game ----------------------------------------------------

  test "from_api describes a finished game fully" do
    finished = game("WSH @ NYG")

    assert_equal({ state: "post", description: "Final", detail: "Final", completed: true }, finished[:status])
    assert_equal [ 21, 24 ], [ finished[:home][:score], finished[:away][:score] ]
    assert_equal [ false, true ], [ finished[:home][:winner], finished[:away][:winner] ]
    assert_equal "5-3-1", finished[:home][:record]
    assert_equal "New York Giants", finished[:home][:name]
    assert_equal "NYG", finished[:home][:abbreviation]
    assert_equal 80_450, finished[:attendance]
    assert_equal "Prime Video", finished[:broadcast]
    assert_includes finished[:recap], "Jayden Daniels"
    assert_match %r{\Ahttps://www\.espn\.com/nfl/game/}, finished[:url]
  end

  test "from_api gives venue details" do
    assert_equal(
      { name: "MetLife Stadium", city: "East Rutherford", state: "NJ", country: "USA", indoor: false },
      game("WSH @ NYG")[:venue]
    )
  end

  test "from_api shows nil, not a misleading 0, for score and winner before a game starts" do
    upcoming = game("KC @ ATL")

    assert_equal "pre", upcoming[:status][:state]
    assert_nil upcoming[:home][:score]
    assert_nil upcoming[:away][:score]
    assert_nil upcoming[:home][:winner]
    assert_nil upcoming[:attendance] # the API says 0 before the game
    assert_nil upcoming[:recap]
  end

  test "from_api shows the real score of a live game, including a real 0, and no winner yet" do
    set_status("KC @ ATL", state: "in", completed: false, description: "In Progress")
    competitors = game_raw("KC @ ATL")["competitions"].first["competitors"]
    competitors.find { |c| c["homeAway"] == "home" }["score"] = "7"
    competitors.find { |c| c["homeAway"] == "away" }["score"] = "0"

    live = game("KC @ ATL")
    assert_equal 7, live[:home][:score]
    assert_equal 0, live[:away][:score]
    assert_nil live[:home][:winner]
    assert_nil live[:away][:winner]
  end

  test "from_api never shows a winner for a game that is not over, even if the API sends one" do
    set_status("KC @ ATL", state: "in", completed: false, description: "In Progress")
    game_raw("KC @ ATL")["competitions"].first["competitors"].each { |c| c["winner"] = true }

    live = game("KC @ ATL")
    assert_nil live[:home][:winner]
    assert_nil live[:away][:winner]
  end

  test "from_api keeps a neutral-site game's venue and note" do
    munich = game("NE VS DET")

    assert munich[:neutral_site]
    assert_equal "NFL Munich Game", munich[:note]
    assert_equal "Germany", munich[:venue][:country]
    assert_equal "Munich", munich[:venue][:city]
    assert_nil munich[:venue][:state]
  end

  test "from_api tolerates a game with missing pieces" do
    game_raw("KC @ ATL").delete("competitions")
    game_raw("KC @ ATL").delete("links")

    broken = game("KC @ ATL")
    assert_equal "KC @ ATL", broken[:short_name]
    assert_nil broken[:home]
    assert_nil broken[:away]
    assert_nil broken[:venue]
    assert_nil broken[:url]
  end

  test "from_api treats broken pieces as missing instead of crashing" do
    raw = game_raw("KC @ ATL")
    competition = raw["competitions"].first
    competition["competitors"].unshift(nil, "junk")        # stray entries before the real teams
    competition["competitors"].each { |c| c["records"] = [ nil, "x" ] if c.is_a?(Hash) }
    competition["notes"] = [ "junk" ]
    competition["headlines"] = [ nil ]
    competition["venue"]["address"] = "somewhere"           # text where an object belongs
    raw["links"] = [ nil, "junk" ]
    game_raw("NE VS DET")["status"] = "oops"
    game_raw("PIT @ CIN")["competitions"] = [ "junk" ]

    broken = game("KC @ ATL")
    assert_equal "ATL", broken[:home][:abbreviation]       # the real teams are still found
    assert_equal "KC", broken[:away][:abbreviation]
    assert_nil broken[:home][:record]
    assert_nil broken[:note]
    assert_nil broken[:recap]
    assert_nil broken[:url]
    assert_nil broken[:venue][:city]
    assert_nil game("NE VS DET")[:status][:state]
    assert_nil game("PIT @ CIN")[:home]
    assert_equal 4, schedule[:games].size
  end

  test "from_api returns no games for an unexpected response" do
    [ nil, [], "oops", {}, { "20261112" => "oops" }, { "20261112" => {} }, { "20261112" => { "games" => [ "x", nil ] } } ].each do |raw|
      assert_equal [], schedule(raw)[:games], "expected #{raw.inspect} to give no games"
    end
  end

  # --- fresh_for: how long a fetched schedule may be served ------------------

  test "fresh_for is 1 hour when the next kickoff is far away" do
    assert_equal 1.hour, fresh_for_at(BASE)
    assert_equal 1.hour, fresh_for_at(Time.utc(2026, 11, 15, 13)) # 90 minutes before the first kickoff
  end

  test "fresh_for shortens so the cache expires at the next kickoff" do
    assert_equal 10.minutes, fresh_for_at(Time.utc(2026, 11, 15, 14, 20))
  end

  test "fresh_for never goes below 1 minute" do
    assert_equal 1.minute, fresh_for_at(Time.utc(2026, 11, 15, 14, 29, 40))
  end

  test "fresh_for is 2 minutes while a game is live" do
    set_status("NE VS DET", state: "in", completed: false)

    assert_equal 2.minutes, fresh_for_at(Time.utc(2026, 11, 15, 15))
  end

  test "fresh_for is 2 minutes when a kickoff has passed but the game still says pre" do
    assert_equal 2.minutes, fresh_for_at(Time.utc(2026, 11, 15, 14, 31))
  end

  test "fresh_for stops treating a late pre game as live 6 hours after its kickoff" do
    finish_all!
    set_status("NE VS DET", state: "pre", completed: false) # kickoff 14:30, never flipped to live
    kickoff = Time.utc(2026, 11, 15, 14, 30)

    assert_equal 2.minutes, fresh_for_at(kickoff + 6.hours - 1.minute)
    assert_equal 1.hour, fresh_for_at(kickoff + 6.hours + 1.minute)
  end

  test "fresh_for is 1 hour for a finished week, so a move to the next week is noticed" do
    finish_all!

    assert_equal 1.hour, fresh_for_at(Time.utc(2026, 11, 17, 12))
  end

  test "fresh_for ignores a postponed game instead of refreshing every minute" do
    finish_all!
    set_status("NE VS DET", state: "post", completed: false, description: "Postponed")

    assert_equal 1.hour, fresh_for_at(Time.utc(2026, 11, 16, 12)) # its old kickoff is in the past
  end

  test "fresh_for does not count down to a postponed game's old kickoff time" do
    finish_all!
    set_status("NE VS DET", state: "post", completed: false, description: "Postponed")

    # Its listed kickoff (14:30) is still ahead, but the game is postponed, so no countdown to it.
    assert_equal 1.hour, fresh_for_at(Time.utc(2026, 11, 15, 14, 20))
  end

  test "grace_for is a day for a finished week and 3 hours otherwise" do
    assert_equal 3.hours, NflSchedule.grace_for(schedule[:games])
    assert_equal 3.hours, NflSchedule.grace_for([])

    finish_all!
    assert_equal 1.day, NflSchedule.grace_for(schedule[:games])
  end

  # --- current: the cache ------------------------------------------------------

  test "current returns fetched_at, the week and the games" do
    travel_to(BASE)

    with_world(FakeNflClient.new(@raw)) do
      result = NflSchedule.current

      assert_equal "2026-11-14T09:00:00Z", result[:fetched_at]
      assert_equal 10, result[:week]
      assert_equal 4, result[:games].size
    end
  end

  test "current calls the API once, then serves from the cache" do
    travel_to(BASE)
    client = FakeNflClient.new(@raw)

    with_world(client) do
      first = NflSchedule.current
      assert_equal first, NflSchedule.current
    end

    assert_equal 1, client.calls
  end

  test "current looks at an upcoming week again after an hour" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      travel_to(BASE)
      NflSchedule.current
      travel_to(BASE + 59.minutes)
      NflSchedule.current
      assert_equal 1, client.calls

      travel_to(BASE + 61.minutes)
      NflSchedule.current
      assert_equal 2, client.calls
    end
  end

  test "current looks at a FINISHED week again within the hour, so the next week is not missed" do
    finish_all!
    client = FakeNflClient.new(@raw)

    with_world(client) do
      travel_to(Time.utc(2026, 11, 17, 12))
      NflSchedule.current
      travel_to(Time.utc(2026, 11, 17, 12, 59))
      NflSchedule.current
      assert_equal 1, client.calls

      travel_to(Time.utc(2026, 11, 17, 13, 1)) # not 7 days later
      NflSchedule.current
      assert_equal 2, client.calls
    end
  end

  test "current looks at a live week every 2 minutes" do
    set_status("NE VS DET", state: "in", completed: false)
    client = FakeNflClient.new(@raw)
    start = Time.utc(2026, 11, 15, 15)

    with_world(client) do
      travel_to(start)
      NflSchedule.current
      travel_to(start + 1.minute)
      NflSchedule.current
      assert_equal 1, client.calls

      travel_to(start + 3.minutes)
      NflSchedule.current
      assert_equal 2, client.calls
    end
  end

  test "current refreshes right at kickoff, not up to an hour later" do
    client = FakeNflClient.new(@raw)
    start = Time.utc(2026, 11, 15, 14, 20) # kickoff is at 14:30

    with_world(client) do
      travel_to(start)
      NflSchedule.current
      travel_to(start + 9.minutes)
      NflSchedule.current
      assert_equal 1, client.calls

      travel_to(start + 11.minutes) # 14:31, the game has started
      NflSchedule.current
      assert_equal 2, client.calls
    end
  end

  test "current refuses to cache an empty schedule" do
    client = FakeNflClient.new({})

    with_world(client) do
      assert_raises(NflApiClient::Error) { NflSchedule.current }
      assert_not Rails.cache.exist?(NflSchedule::CACHE_KEY)
      travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown before asking again

      assert_raises(NflApiClient::Error) { NflSchedule.current }
    end

    assert_equal 2, client.calls # nothing was cached, so it asked again
  end

  # --- current: the safety net -----------------------------------------------

  test "current serves the old upcoming week for 3 hours past expiry if the API fails" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      travel_to(BASE)
      old = NflSchedule.current
      client.response = NflApiClient::Error.new("down")

      travel_to(BASE + 1.hour + 2.hours + 59.minutes)
      assert_equal old, NflSchedule.current
    end
  end

  test "current gives up on an upcoming week's backup after 3 hours past expiry" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      travel_to(BASE)
      NflSchedule.current
      client.response = NflApiClient::Error.new("down")

      travel_to(BASE + 1.hour + 3.hours + 1.minute)
      assert_raises(NflApiClient::Error) { NflSchedule.current }
    end
  end

  # --- fresh_for / grace_for: the options for a chosen week -------------------

  test "fresh_for keeps a finished week for the given long time" do
    finish_all!

    assert_equal 7.days, NflSchedule.fresh_for(schedule[:games], BASE, finished_ttl: 7.days)
  end

  test "fresh_for ignores the long time while any game is still to come" do
    assert_equal 1.hour, NflSchedule.fresh_for(schedule[:games], BASE, finished_ttl: 7.days)
  end

  test "fresh_for ignores the long time while a game is live" do
    finish_all!
    set_status("KC @ ATL", state: "in", completed: false)

    assert_equal 2.minutes, NflSchedule.fresh_for(schedule[:games], BASE, finished_ttl: 7.days)
  end

  test "grace_for can be told a longer grace for finished weeks" do
    assert_equal 3.hours, NflSchedule.grace_for(schedule[:games], finished_grace: 30.days)

    finish_all!
    assert_equal 30.days, NflSchedule.grace_for(schedule[:games], finished_grace: 30.days)
  end

  # --- for: a chosen week ------------------------------------------------------

  test "for returns the chosen week's games, with fetched_at" do
    travel_to(BASE)

    with_world(EchoClient.new(@raw)) do
      result = NflSchedule.for(2026, 10)

      assert_equal [ 2026, 10 ], [ result[:year], result[:week] ]
      assert_equal "2026-11-14T09:00:00Z", result[:fetched_at]
      assert_equal 4, result[:games].size
    end
  end

  test "for asks RapidAPI for exactly the year and week requested, as text or numbers" do
    travel_to(BASE)
    client = EchoClient.new(@raw)

    with_world(client) do
      NflSchedule.for(2025, 3)
      NflSchedule.for("2026", "10")
    end

    assert_equal [ [ "2025", "3" ], [ "2026", "10" ] ], client.asked
  end

  test "for caches each year and week separately" do
    travel_to(BASE)
    client = EchoClient.new(@raw)

    with_world(client) do
      2.times { NflSchedule.for(2026, 10) }
      assert_equal 1, client.calls

      2.times { NflSchedule.for(2026, 11) } # another week: its own call
      assert_equal 2, client.calls

      NflSchedule.for(2025, 10)             # another year: its own call
      assert_equal 3, client.calls
    end
  end

  test "for refuses a silly year or week without calling RapidAPI or caching anything" do
    travel_to(BASE)
    client = EchoClient.new(@raw)
    bad = [ [ "abc", "1" ], [ "2026", "abc" ], [ "", "1" ], [ "2026", "" ], [ nil, "1" ], [ "2026", nil ],
            [ "1999", "1" ], [ "2028", "1" ], [ "20262", "1" ], [ "02026", "1" ], [ " 2026", "1" ],
            [ "2026", "0" ], [ "2026", "19" ], [ "2026", "99" ], [ "2026", "01" ], [ "2026", "-1" ],
            [ "2026", "1.5" ], [ "2026", "1e1" ], [ "2026", "1 " ], [ "2026", "1\n" ], [ "2026\n", "1" ] ]

    with_world(client) do
      bad.each do |year, week|
        assert_raises(NflSchedule::UnknownSchedule, "expected #{year.inspect}/#{week.inspect} to be refused") do
          NflSchedule.for(year, week)
        end
        assert_not Rails.cache.exist?(NflSchedule.week_key(year, week))
      end
    end

    assert_equal 0, client.calls
  end

  test "for accepts every year from 2000 to next year and weeks 1 to 18" do
    travel_to(BASE)
    client = EchoClient.new(@raw)

    with_world(client) do
      [ [ 2000, 1 ], [ 2026, 18 ], [ 2027, 1 ], [ 2026, 9 ] ].each do |year, week|
        assert_nothing_raised { NflSchedule.for(year, week) }
      end
    end

    assert_equal 4, client.calls
  end

  test "for keeps a finished week for 7 days" do
    finish_all!
    client = EchoClient.new(@raw)

    with_world(client) do
      travel_to(BASE)
      NflSchedule.for(2026, 10)
      travel_to(BASE + 6.days + 23.hours)
      NflSchedule.for(2026, 10)
      assert_equal 1, client.calls

      travel_to(BASE + 7.days + 1.minute)
      NflSchedule.for(2026, 10)
      assert_equal 2, client.calls
    end
  end

  test "for looks at a week with games still to come again after an hour" do
    near = Time.utc(2026, 11, 15, 9) # under a day before the 14:30 kickoff: normal hourly rule
    client = EchoClient.new(@raw)

    with_world(client) do
      travel_to(near)
      NflSchedule.for(2026, 10)
      travel_to(near + 59.minutes)
      NflSchedule.for(2026, 10)
      assert_equal 1, client.calls

      travel_to(near + 61.minutes)
      NflSchedule.for(2026, 10)
      assert_equal 2, client.calls
    end
  end

  # The first upcoming kickoff in the fixture is 2026-11-15 14:30 UTC.
  test "fresh_for with far_ttl keeps a far-away week up to 12 hours" do
    games = schedule[:games]
    three_days_before = Time.utc(2026, 11, 12, 14, 30)

    assert_equal 12.hours, NflSchedule.fresh_for(games, three_days_before, far_ttl: 12.hours)
  end

  test "fresh_for with far_ttl never keeps the copy past one day before kickoff" do
    games = schedule[:games]

    # 29.5 hours before kickoff: kept 5.5 hours, until exactly one day before.
    assert_equal 5.5.hours, NflSchedule.fresh_for(games, Time.utc(2026, 11, 14, 9), far_ttl: 12.hours)
    # 24.5 hours before: still at least the normal hour.
    assert_equal 1.hour, NflSchedule.fresh_for(games, Time.utc(2026, 11, 14, 14), far_ttl: 12.hours)
  end

  test "fresh_for with far_ttl uses the normal rules within a day of kickoff" do
    games = schedule[:games]

    assert_equal 1.hour, NflSchedule.fresh_for(games, Time.utc(2026, 11, 15, 9), far_ttl: 12.hours)
    assert_equal 10.minutes, NflSchedule.fresh_for(games, Time.utc(2026, 11, 15, 14, 20), far_ttl: 12.hours)
  end

  test "the current week keeps the hourly rule even when kickoff is days away" do
    assert_equal 1.hour, NflSchedule.fresh_for(schedule[:games], Time.utc(2026, 11, 12, 14, 30))
  end

  test "for keeps a far-away week for 12 hours, not 1" do
    client = EchoClient.new(@raw)
    start = Time.utc(2026, 11, 12, 14, 30) # three days before kickoff

    with_world(client) do
      travel_to(start)
      NflSchedule.for(2026, 10)
      travel_to(start + 11.hours + 59.minutes)
      NflSchedule.for(2026, 10)
      assert_equal 1, client.calls

      travel_to(start + 12.hours + 1.minute)
      NflSchedule.for(2026, 10)
      assert_equal 2, client.calls
    end
  end

  test "for looks at a week with a live game every 2 minutes" do
    set_status("NE VS DET", state: "in", completed: false)
    client = EchoClient.new(@raw)
    start = Time.utc(2026, 11, 15, 15)

    with_world(client) do
      travel_to(start)
      NflSchedule.for(2026, 10)
      travel_to(start + 1.minute)
      NflSchedule.for(2026, 10)
      assert_equal 1, client.calls

      travel_to(start + 3.minutes)
      NflSchedule.for(2026, 10)
      assert_equal 2, client.calls
    end
  end

  test "for serves a finished week's backup for 30 days past expiry, then gives up" do
    finish_all!
    client = EchoClient.new(@raw)

    with_world(client) do
      travel_to(BASE)
      old = NflSchedule.for(2026, 10)
      client.failure = NflApiClient::Error.new("down")

      travel_to(BASE + 7.days + 29.days + 23.hours)
      assert_equal old, NflSchedule.for(2026, 10)
    end

    other = EchoClient.new(@raw)
    with_world(other) do
      travel_to(BASE)
      NflSchedule.for(2026, 10)
      other.failure = NflApiClient::Error.new("down")

      travel_to(BASE + 7.days + 30.days + 1.minute)
      assert_raises(NflApiClient::Error) { NflSchedule.for(2026, 10) }
    end
  end

  test "for serves the backup of a week with games to come for only 3 hours past expiry" do
    near = Time.utc(2026, 11, 15, 9) # under a day before the 14:30 kickoff: normal hourly rule
    client = EchoClient.new(@raw)

    with_world(client) do
      travel_to(near)
      old = NflSchedule.for(2026, 10)
      client.failure = NflApiClient::Error.new("down")

      travel_to(near + 1.hour + 2.hours + 59.minutes)
      assert_equal old, NflSchedule.for(2026, 10)
    end

    other = EchoClient.new(@raw)
    with_world(other) do
      travel_to(near)
      NflSchedule.for(2026, 10)
      other.failure = NflApiClient::Error.new("down")

      travel_to(near + 1.hour + 3.hours + 1.minute)
      assert_raises(NflApiClient::Error) { NflSchedule.for(2026, 10) }
    end
  end

  test "for refuses to cache an answer for a different week than asked" do
    travel_to(BASE)
    client = FakeNflClient.new(@raw) # always answers "week 10 of 2026", whatever it is asked

    with_world(client) do
      assert_raises(NflApiClient::Error) { NflSchedule.for(2026, 3) }
      assert_raises(NflApiClient::Error) { NflSchedule.for(2025, 10) }

      assert_not Rails.cache.exist?(NflSchedule.week_key("2026", "3"))
      assert_not Rails.cache.exist?(NflSchedule.week_key("2025", "10"))
      assert_nothing_raised { NflSchedule.for(2026, 10) } # the right week is fine
    end
  end

  test "for refuses to cache an empty week" do
    travel_to(BASE)

    with_world(FakeNflClient.new({})) do
      error = assert_raises(NflApiClient::Error) { NflSchedule.for(2026, 10) }

      assert_match "no games", error.message # the clear reason, not "sent week nil"
      assert_not Rails.cache.exist?(NflSchedule.week_key("2026", "10"))
    end
  end

  test "for turns the API's not-found into UnknownSchedule and caches nothing for the week" do
    travel_to(BASE)

    with_world(FakeNflClient.new(NflApiClient::NotFound.new("not found"))) do
      assert_raises(NflSchedule::UnknownSchedule) { NflSchedule.for(2020, 18) }
      assert_not Rails.cache.exist?(NflSchedule.week_key("2020", "18"))
    end
  end

  test "for remembers a week the API does not have for an hour" do
    travel_to(BASE)
    client = FakeNflClient.new(NflApiClient::NotFound.new("not found"))

    with_world(client) do
      2.times { assert_raises(NflSchedule::UnknownSchedule) { NflSchedule.for(2020, 18) } }
      assert_equal 1, client.calls # the second request never reached the API

      travel_to(BASE + 1.hour + 1.minute)
      assert_raises(NflSchedule::UnknownSchedule) { NflSchedule.for(2020, 18) }
      assert_equal 2, client.calls # an hour later it asks again
    end
  end

  test "for treats an ordinary API failure as an error and does not remember it as unknown" do
    travel_to(BASE)
    client = FakeNflClient.new(NflApiClient::Error.new("down"))

    with_world(client) do
      2.times do
        error = assert_raises(NflApiClient::Error) { NflSchedule.for(2026, 10) }
        assert_instance_of NflApiClient::Error, error
        travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown, then try again
      end
    end

    assert_equal 2, client.calls
  end

  test "the current week and a chosen week never share a cache entry" do
    travel_to(BASE)
    client = FakeNflClient.new(@raw)

    with_world(client) do
      NflSchedule.current
      NflSchedule.for(2026, 10) # same data, but its own entry and its own call
    end

    assert_equal 2, client.calls
    keys = [ NflSchedule::CACHE_KEY, NflSchedule.week_key("2026", "10"), NflSchedule.missing_key("2026", "10") ]
    assert_equal keys.size, keys.uniq.size
  end

  test "current serves a finished week's backup for a full day past expiry" do
    finish_all!
    client = FakeNflClient.new(@raw)
    start = Time.utc(2026, 11, 17, 12)

    with_world(client) do
      travel_to(start)
      old = NflSchedule.current
      client.response = NflApiClient::Error.new("down")

      travel_to(start + 1.hour + 23.hours + 59.minutes)
      assert_equal old, NflSchedule.current
    end
  end
end
