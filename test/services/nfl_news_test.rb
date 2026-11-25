require "test_helper"

class NflNewsTest < ActiveSupport::TestCase
  setup do
    # binread + JSON.parse mimics the real client: Net::HTTP hands us raw bytes.
    # The fixture is stored NOT newest-first on purpose: 12 Nov 23:29, 13 Nov 07:26, 13 Nov 04:35.
    @raw = JSON.parse(file_fixture("nfl-news.json").binread)
  end

  def article(id)
    NflNews.from_api(@raw).find { |a| a[:id] == id }
  end

  # --- from_api: flattening ------------------------------------------------

  test "from_api turns each article into a small clean hash" do
    result = article(50469309)

    assert_equal %i[byline headline id image players published_at summary teams type url], result.keys.sort
    assert_equal "Jordan Raanan", result[:byline]
    assert_equal "2026-11-13T07:26:59Z", result[:published_at]
    assert_equal "HeadlineNews", result[:type]
    assert_match %r{\Ahttps://www\.espn\.com/nfl/story/}, result[:url]
  end

  test "from_api sorts newest first, whatever order the API sends" do
    ids = NflNews.from_api(@raw).map { |a| a[:id] }

    assert_equal [ 50469309, 50468530, 50465631 ], ids
  end

  test "from_api splits categories into teams and players and ignores the rest" do
    result = article(50469309)

    assert_equal [ "New York Giants", "Washington Commanders" ], result[:teams]
    assert_equal [ "Jameis Winston" ], result[:players]
    assert_not_includes result[:teams] + result[:players], "NFL"           # league category
    assert_not_includes result[:teams] + result[:players], "Jordan Raanan" # writer category
  end

  test "from_api gives nil when there is no byline" do
    assert_nil article(50468530)[:byline]
  end

  test "from_api prefers the header image over the first image" do
    raw_article = @raw.find { |a| a["id"] == 50469309 }
    raw_article["images"].reverse! # now the header image is no longer first

    header = raw_article["images"].find { |i| i["type"] == "header" }["url"]
    assert_equal header, article(50469309)[:image]
  end

  test "from_api tolerates missing images, links and categories" do
    raw_article = @raw.first
    raw_article.delete("images")
    raw_article.delete("links")
    raw_article.delete("categories")

    result = NflNews.from_api([ raw_article ]).first
    assert_nil result[:image]
    assert_nil result[:url]
    assert_equal [], result[:teams]
    assert_equal [], result[:players]
  end

  test "from_api keeps non-ASCII characters intact as UTF-8" do
    headline = article(50465631)[:headline]

    assert_includes headline, "Mendoza’s" # curly apostrophe
    assert_equal Encoding::UTF_8, headline.encoding
    assert headline.valid_encoding?
    assert_nothing_raised { { articles: [ headline ] }.to_json }
  end

  test "from_api returns an empty list for an unexpected response" do
    assert_equal [], NflNews.from_api({ "message" => "oops" })
    assert_equal [], NflNews.from_api(nil)
  end

  # --- latest: caching -----------------------------------------------------

  test "latest includes fetched_at and the articles" do
    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) do
        freeze_time do
          result = NflNews.latest

          assert_equal Time.current.utc.iso8601, result[:fetched_at]
          assert_equal 3, result[:articles].size
        end
      end
    end
  end

  test "latest calls the API once, then serves from the cache" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        first = NflNews.latest
        second = NflNews.latest

        assert_equal first, second
      end

      assert_equal 1, client.calls
    end
  end

  test "latest is still cached just before 8 hours" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        NflNews.latest
        travel(7.hours + 59.minutes) { NflNews.latest }
      end

      assert_equal 1, client.calls
    end
  end

  test "latest makes a fresh API call after 8 hours" do
    with_memory_cache do
      client = FakeNflClient.new(@raw)

      NflApiClient.stub(:new, client) do
        NflNews.latest
        travel(8.hours + 1.minute) { NflNews.latest }
      end

      assert_equal 2, client.calls
    end
  end

  test "latest serves the old news when the API fails after 8 hours" do
    with_memory_cache do
      old = nil
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) { old = NflNews.latest }

      travel(8.hours + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new(NflApiClient::Error.new("down"))) do
          assert_equal old, NflNews.latest # same data, same old fetched_at
        end
      end
    end
  end

  test "latest does not cache a failure" do
    with_memory_cache do
      NflApiClient.stub(:new, FakeNflClient.new(NflApiClient::Error.new("boom"))) do
        assert_raises(NflApiClient::Error) { NflNews.latest }
      end
      assert_not Rails.cache.exist?(NflNews::CACHE_KEY)
      travel(StaleCache::FAILURE_COOLDOWN + 1.second) # wait out the cooldown before asking again

      NflApiClient.stub(:new, FakeNflClient.new(@raw)) do
        assert_equal 3, NflNews.latest[:articles].size
      end
    end
  end

  test "latest does not cache an empty or error answer as no news" do
    [ [], { "message" => "You have exceeded the rate limit" } ].each do |answer|
      with_memory_cache do
        NflApiClient.stub(:new, FakeNflClient.new(answer)) do
          assert_raises(NflApiClient::Error, "expected #{answer.inspect} to be a failure") { NflNews.latest }
        end
        assert_not Rails.cache.exist?(NflNews::CACHE_KEY)
      end
    end
  end

  test "latest serves the old news when the API sends no articles after 8 hours" do
    with_memory_cache do
      old = nil
      NflApiClient.stub(:new, FakeNflClient.new(@raw)) { old = NflNews.latest }

      travel(8.hours + 1.minute) do
        NflApiClient.stub(:new, FakeNflClient.new([])) do
          assert_equal old, NflNews.latest
        end
      end
    end
  end

  test "from_api skips broken articles and treats broken pieces as missing" do
    good_ids = NflNews.from_api(@raw).map { |a| a[:id] }

    first = @raw.first
    first["links"] = "junk"
    first["images"] = [ nil, "junk" ] + Array(first["images"])
    first["categories"] = [ nil, "junk" ] + Array(first["categories"])
    @raw << nil << "junk" << 42

    result = NflNews.from_api(@raw)
    assert_equal good_ids, result.map { |a| a[:id] }

    broken = result.find { |a| a[:id] == first["id"] }
    assert_nil broken[:url]
    assert_not_nil broken[:image] # the real images are still found
  end

  test "a broken news item no longer breaks the news section of a player overview" do
    raw = JSON.parse(file_fixture("player-overview.json").binread)
    raw["player_overview"]["news"] = Array(raw["player_overview"]["news"]) + [ nil, "junk" ]

    assert_nothing_raised { NflPlayerOverview.from_api(raw) }
  end
end
