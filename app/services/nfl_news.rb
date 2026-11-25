# Turns the raw NFL news response (a list of 20 big article hashes)
# into the small, clean articles that our own endpoint returns.
class NflNews
  CACHE_KEY = "nfl/news/v1".freeze
  CACHE_TTL = 8.hours
  STALE_GRACE = 1.day # if the API is down, serve the old news up to 1 day past expiry

  # The method our controller will call. Returns the articles plus the time
  # they were fetched, so API users can see how old the news is.
  def self.latest
    StaleCache.fetch(CACHE_KEY, expires_in: CACHE_TTL, grace: STALE_GRACE) do
      articles = from_api(NflApiClient.new.news)
      # No articles means an empty or error answer (e.g. {"message": "..."} with HTTP 200).
      # Never cache that as "no news" for 8 hours: fail, so the backup is served instead.
      # (Only here: in a player overview, a player with no news is normal.)
      raise NflApiClient::Error, "NFL API news had no articles" if articles.empty?

      { fetched_at: Time.current.utc.iso8601, articles: articles }
    end
  end

  # raw: the parsed JSON from NflApiClient#news. For this API it is an Array.
  # returns: an Array of small Hashes, newest article first.
  # An entry that is not an article (null, text...) is skipped instead of crashing; this
  # also protects the news section of GET /players/:id, which uses the same code.
  def self.from_api(raw)
    return [] unless raw.is_a?(Array)

    raw.select { |article| article.is_a?(Hash) }
       .map { |article| format_article(article) }
       .sort_by { |article| article[:published_at].to_s }
       .reverse
  end

  def self.format_article(article)
    {
      id: article["id"],
      headline: article["headline"],
      summary: article["description"],
      type: article["type"],
      published_at: article["published"],
      byline: article["byline"].presence,
      image: first_image_url(article["images"]),
      url: object(object(article["links"])["web"])["href"],
      teams: category_names(article["categories"], "team"),
      players: category_names(article["categories"], "athlete")
    }
  end

  # Prefer the "header" picture; fall back to whatever image comes first.
  def self.first_image_url(images)
    images = Array(images).select { |image| image.is_a?(Hash) }
    (images.find { |image| image["type"] == "header" } || images.first)&.fetch("url", nil)
  end

  # `categories` mixes teams, players, writers... keep only one kind.
  def self.category_names(categories, kind)
    Array(categories)
      .select { |category| object(category)["type"] == kind }
      .filter_map { |category| category["description"].presence }
  end

  # The value if it is an object (Hash), otherwise an empty one, so a null or a stray
  # string where an object belongs reads as "missing" instead of crashing with a 500.
  def self.object(value)
    value.is_a?(Hash) ? value : {}
  end

  private_class_method :format_article, :first_image_url, :category_names, :object
end
