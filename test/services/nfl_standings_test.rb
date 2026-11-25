require "test_helper"

class NflStandingsTest < ActiveSupport::TestCase
  BASE = Time.utc(2026, 11, 14, 9) # the "current year" for the year checks is 2026

  # A fake RapidAPI that answers for the year it is ASKED about: the fixture's table,
  # relabelled with that season. It remembers the questions and can be told to fail.
  class EchoClient
    attr_reader :calls, :asked
    attr_writer :failure

    def initialize(raw)
      @raw = raw
      @calls = 0
      @asked = []
    end

    def standings(year)
      @calls += 1
      @asked << year
      raise @failure if @failure

      copy = JSON.parse(JSON.generate(@raw))
      copy["standings"]["season"] = year.to_i
      copy
    end
  end

  setup do
    travel_to(BASE)
    @raw = JSON.parse(file_fixture("standings.json").binread)
  end

  def entry(abbreviation) = @raw["standings"]["entries"].find { |e| e["team"]["abbreviation"] == abbreviation }

  def stats_named(abbreviation, name) = entry(abbreviation)["stats"].select { |s| s["name"] == name }

  def standings(raw = @raw) = NflStandings.from_api(raw)

  def division(name) = standings[:divisions].find { |d| d[:name] == name }

  def team(abbreviation)
    standings[:divisions].flat_map { |d| d[:teams] }.find { |t| t.dig(:team, :abbreviation) == abbreviation }
  end

  def with_world(client)
    with_memory_cache do
      NflApiClient.stub(:new, client) { yield }
    end
  end

  # --- from_api: grouping ----------------------------------------------------

  test "from_api reads the season from the table" do
    assert_equal 2026, standings[:year]
  end

  test "from_api groups the alphabetical list of teams into divisions, AFC first, by name" do
    assert_equal [ "AFC East", "NFC East", "NFC South", "NFC West" ], standings[:divisions].map { |d| d[:name] }
  end

  test "from_api names each division and its conference from our table" do
    nfc_west = division("NFC West")

    assert_equal 3, nfc_west[:id]
    assert_equal "NFC", nfc_west[:conference]
    assert_equal %w[ARI SEA], nfc_west[:teams].map { |t| t.dig(:team, :abbreviation) }.sort
  end

  test "from_api keeps a division it has no name for, and lists it last" do
    stats_named("ATL", "divisionId").first["value"] = 99

    unknown = standings[:divisions].last
    assert_equal 99, unknown[:id]
    assert_nil unknown[:name]
    assert_nil unknown[:conference]
    assert_equal [ "ATL" ], unknown[:teams].map { |t| t.dig(:team, :abbreviation) }
  end

  test "from_api puts each division's teams in division-rank order, whatever order the API sends" do
    assert_equal %w[SEA ARI], division("NFC West")[:teams].map { |t| t.dig(:team, :abbreviation) }
    assert_equal %w[BUF MIA], division("AFC East")[:teams].map { |t| t.dig(:team, :abbreviation) } # MIA came first in the file
  end

  test "our division table lists 8 divisions of 2 conferences" do
    assert_equal 8, NflStandings::DIVISIONS.size
    assert_equal({ "AFC" => 4, "NFC" => 4 }, NflStandings::DIVISIONS.values.map { |d| d[:conference] }.tally)
    assert_equal 8, NflStandings::DIVISIONS.values.map { |d| d[:name] }.uniq.size
  end

  # --- from_api: one team ----------------------------------------------------

  test "from_api gives each team a small, clean row" do
    buffalo = team("BUF")

    assert_equal %i[conference_rank conference_record division_rank division_record games_behind losses
                    point_differential points_against points_for record strength_of_schedule
                    strength_of_victory team ties win_percent wins],
                 buffalo.keys.sort
    assert_equal({ id: "2", name: "Buffalo Bills", abbreviation: "BUF", logo: "https://a.espncdn.com/i/teamlogos/nfl/500/buf.png" },
                 buffalo[:team])
  end

  test "from_api reads a team's numbers" do
    buffalo = team("BUF")

    assert_equal "7-1", buffalo[:record]
    assert_equal [ 7, 1, 0 ], [ buffalo[:wins], buffalo[:losses], buffalo[:ties] ]
    assert_equal 0.875, buffalo[:win_percent]
    assert_equal 69, buffalo[:point_differential]
    assert_equal [ 1, 1 ], [ buffalo[:division_rank], buffalo[:conference_rank] ]
    assert_equal 0, buffalo[:games_behind]
  end

  test "from_api shows a tie in the record and the tie count" do
    giants = team("NYG")

    assert_equal "5-3-1", giants[:record]
    assert_equal 1, giants[:ties]
    assert_equal 0.6111, giants[:win_percent] # rounded to 4 places
  end

  test "from_api takes the first copy of a statistic the API lists twice" do
    stats_named("SEA", "wins").last["value"] = 999 # the second copy
    stats_named("SEA", "wins").first["value"] = 5

    assert_equal 5, team("SEA")[:wins]
  end

  test "from_api leaves out projections, opponent lists and other extras" do
    json = standings.to_json

    assert_not_includes json, "projected"
    assert_not_includes json, "lossOpponents"
    assert_not_includes json, "Playoff"
  end

  test "from_api gives nil, not a crash, for statistics the API did not send" do
    entry("ARI")["stats"].reject! { |s| %w[strengthOfSchedule pointsScored overall].include?(s["name"]) }

    arizona = team("ARI")
    assert_nil arizona[:strength_of_schedule]
    assert_nil arizona[:points_for]
    assert_nil arizona[:record]
    assert_equal 3, arizona[:wins] # the rest is still there
  end

  test "from_api ignores entries that are not teams" do
    @raw["standings"]["entries"] << "oops" << nil

    assert_equal 6, standings[:divisions].sum { |d| d[:teams].size }
  end

  test "from_api returns no divisions for an unexpected response" do
    [ nil, [], "oops", {}, { "standings" => nil }, { "standings" => "x" }, { "standings" => { "entries" => "x" } } ].each do |raw|
      assert_equal({ year: nil, divisions: [] }, standings(raw), "expected #{raw.inspect} to give no divisions")
    end
  end

  # --- for: one season, cached -----------------------------------------------

  test "for returns fetched_at, the year and the divisions" do
    with_world(EchoClient.new(@raw)) do
      result = NflStandings.for(2026)

      assert_equal "2026-11-14T09:00:00Z", result[:fetched_at]
      assert_equal 2026, result[:year]
      assert_equal 4, result[:divisions].size
    end
  end

  test "for asks RapidAPI about the right year, given as text or a number" do
    client = EchoClient.new(@raw)

    with_world(client) do
      NflStandings.for(2025)
      NflStandings.for("2026")
    end

    assert_equal %w[2025 2026], client.asked
  end

  test "for caches each season separately" do
    client = EchoClient.new(@raw)

    with_world(client) do
      2.times { NflStandings.for(2026) }
      assert_equal 1, client.calls

      2.times { NflStandings.for(2025) } # another season: its own call
      assert_equal 2, client.calls
    end
  end

  test "for refuses a silly year without calling RapidAPI or caching anything" do
    client = EchoClient.new(@raw)
    bad = [ "abc", "", nil, "2001", "1999", "2027", "2100", "02026", "20262", " 2026", "2026 ", "2026\n", "-2026", "2026.5", "2e3" ]

    with_world(client) do
      bad.each do |year|
        assert_raises(NflStandings::UnknownStandings, "expected #{year.inspect} to be refused") do
          NflStandings.for(year)
        end
        assert_not Rails.cache.exist?(NflStandings.cache_key(year))
      end
    end

    assert_equal 0, client.calls
  end

  test "for accepts every year from 2002 up to this year" do
    client = EchoClient.new(@raw)

    with_world(client) do
      [ 2002, 2010, 2026 ].each { |year| assert_nothing_raised { NflStandings.for(year) } }
    end

    assert_equal 3, client.calls
  end

  test "for keeps a table for 8 hours" do
    client = EchoClient.new(@raw)

    with_world(client) do
      NflStandings.for(2026)
      travel_to(BASE + 7.hours + 59.minutes)
      NflStandings.for(2026)
      assert_equal 1, client.calls

      travel_to(BASE + 8.hours + 1.minute)
      NflStandings.for(2026)
      assert_equal 2, client.calls
    end
  end

  test "for serves the old table for 3 days past expiry if the API fails, then gives up" do
    client = EchoClient.new(@raw)

    with_world(client) do
      old = NflStandings.for(2026)
      client.failure = NflApiClient::Error.new("down")

      travel_to(BASE + 8.hours + 2.days + 23.hours)
      assert_equal old, NflStandings.for(2026)
    end

    other = EchoClient.new(@raw)
    with_world(other) do
      travel_to(BASE) # back to the start: the first half moved the clock
      NflStandings.for(2026)
      other.failure = NflApiClient::Error.new("down")

      travel_to(BASE + 8.hours + 3.days + 1.minute)
      assert_raises(NflApiClient::Error) { NflStandings.for(2026) }
    end
  end

  # --- for: when the API does not have the season ----------------------------

  test "for refuses a table from a different season than asked, and caches nothing under that year" do
    client = FakeNflClient.new(@raw) # always answers "season 2026", whatever it is asked

    with_world(client) do
      assert_raises(NflStandings::UnknownStandings) { NflStandings.for(2025) }

      assert_not Rails.cache.exist?(NflStandings.cache_key("2025"))
      assert_nothing_raised { NflStandings.for(2026) } # the right season is fine
    end
  end

  test "for remembers a season the API does not have for an hour" do
    client = FakeNflClient.new(@raw)

    with_world(client) do
      2.times { assert_raises(NflStandings::UnknownStandings) { NflStandings.for(2025) } }
      assert_equal 1, client.calls # the second request never reached the API

      travel_to(BASE + 1.hour + 1.minute)
      assert_raises(NflStandings::UnknownStandings) { NflStandings.for(2025) }
      assert_equal 2, client.calls # an hour later it asks again
    end
  end

  test "for turns the API's not-found into UnknownStandings" do
    with_world(FakeNflClient.new(NflApiClient::NotFound.new("not found"))) do
      assert_raises(NflStandings::UnknownStandings) { NflStandings.for(2020) }
    end
  end

  test "for refuses to cache a table with no teams, and says why" do
    empty = { "standings" => { "season" => 2026, "entries" => [] } }

    with_world(FakeNflClient.new(empty)) do
      error = assert_raises(NflApiClient::Error) { NflStandings.for(2026) }

      assert_instance_of NflApiClient::Error, error # a failure (502), not "unknown year" (404)
      assert_match "no teams", error.message
      assert_not Rails.cache.exist?(NflStandings.cache_key("2026"))
    end
  end

  test "for treats an ordinary API failure as an error and does not remember it as unknown" do
    client = FakeNflClient.new(NflApiClient::Error.new("down"))

    with_world(client) do
      2.times do
        error = assert_raises(NflApiClient::Error) { NflStandings.for(2026) }
        assert_instance_of NflApiClient::Error, error
        travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown, then try again
      end
    end

    assert_equal 2, client.calls
  end

  # --- current ---------------------------------------------------------------

  test "current shows the season the schedule says is current" do
    client = EchoClient.new(@raw)

    NflSchedule.stub(:current, { year: 2025, week: 18 }) do
      with_world(client) { assert_equal 2025, NflStandings.current[:year] }
    end

    assert_equal %w[2025], client.asked
  end

  test "current and for share one cache entry for the same season" do
    client = EchoClient.new(@raw)

    NflSchedule.stub(:current, { year: 2026 }) do
      with_world(client) do
        NflStandings.current
        NflStandings.for(2026)
        NflStandings.current
      end
    end

    assert_equal 1, client.calls
  end

  test "current fails clearly when the schedule cannot say which season it is" do
    client = EchoClient.new(@raw)

    NflSchedule.stub(:current, { year: nil }) do
      with_world(client) do
        error = assert_raises(NflApiClient::Error) { NflStandings.current }
        assert_match "which season", error.message
      end
    end

    assert_equal 0, client.calls
  end

  test "current passes on a failure to load the schedule" do
    failing = -> { raise NflApiClient::Error, "schedule down" }

    NflSchedule.stub(:current, failing) do
      with_world(EchoClient.new(@raw)) do
        assert_raises(NflApiClient::Error) { NflStandings.current }
      end
    end
  end
end
