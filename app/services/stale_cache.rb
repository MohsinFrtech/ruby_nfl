# A cache with a safety net.
#
# Normal cache:  fresh copy for `expires_in`, then fetch again.
# Safety net:    every successful fetch ALSO saves a "backup" copy that lives
#                `grace` longer. If the next fetch fails (NflApiClient::Error),
#                we serve the backup instead of an error.
#
# Two modes:
#   fixed time       expires_in: 8.hours            (most endpoints)
#   time from data   expires_in: ->(data) { ... }   (the schedule: a game that is
#                    live needs a short cache, a finished week a long one, and
#                    only the fetched data tells us which)
class StaleCache
  # If the first visitor after expiry arrives within these seconds, the old copy is
  # kept for others while that visitor refreshes. It does nothing for later visitors.
  # (Fixed-time mode only.)
  RACE_CONDITION_TTL = 10.seconds

  # While serving a backup, wait this long before trying the real API again.
  # Without it, EVERY visitor during an outage would wait for the API to time out.
  RETRY_AFTER = 5.minutes

  # A failure with NO backup to serve is remembered this long. Until then every visitor
  # gets the error at once and RapidAPI is not called, so a long outage (or an API that
  # keeps sending bad answers) costs at most one call a minute per key, not one per visitor.
  FAILURE_COOLDOWN = 1.minute

  # key:        cache key, e.g. "nfl/news/v1"
  # expires_in: how long the fresh copy is used (e.g. 8.hours), OR a function that
  #             receives the freshly fetched data and returns that duration
  # grace:      how long AFTER expiry the backup may still be served (e.g. 1.day),
  #             OR a function of the fetched data (same idea as expires_in)
  # block:      does the real work (call the API, format the data)
  def self.fetch(key, expires_in:, grace:, &block)
    failed = Rails.cache.read(failure_key(key))
    raise NflApiClient::Error, "#{key}: still cooling down after: #{failed}" unless failed.nil?

    if expires_in.respond_to?(:call)
      fetch_by_data(key, expires_in: expires_in, grace: grace, &block)
    else
      fetch_fixed(key, expires_in: expires_in, grace: grace, &block)
    end
  end

  def self.fetch_fixed(key, expires_in:, grace:, &block)
    Rails.cache.fetch(key, expires_in: expires_in, race_condition_ttl: RACE_CONDITION_TTL) do
      fresh = block.call
      Rails.cache.write(backup_key(key), fresh, expires_in: expires_in + grace)
      fresh
    end
  rescue NflApiClient::Error => error
    serve_backup(key, error)
  end

  # Rails.cache.fetch needs the lifetime BEFORE it runs the block, but here the
  # lifetime depends on what the block returns. So: read, fetch, then write by hand.
  def self.fetch_by_data(key, expires_in:, grace:, &block)
    cached = Rails.cache.read(key)
    return cached unless cached.nil?

    fresh = block.call
    lifetime = expires_in.call(fresh)
    backup_extra = grace.respond_to?(:call) ? grace.call(fresh) : grace

    Rails.cache.write(key, fresh, expires_in: lifetime)
    Rails.cache.write(backup_key(key), fresh, expires_in: lifetime + backup_extra)
    fresh
  rescue NflApiClient::Error => error
    serve_backup(key, error)
  end

  # Called when the real fetch failed: use the backup if there is one.
  def self.serve_backup(key, error)
    backup = Rails.cache.read(backup_key(key))

    if backup.nil? # nothing to fall back on: let the 502 happen, and pause new calls for a minute
      # "Not found" is not an outage: the services remember it themselves (and answer 404).
      # "Budget exceeded" made no call at all, so there is nothing to cool down from.
      unless error.is_a?(NflApiClient::NotFound) || error.is_a?(NflApiClient::BudgetExceeded)
        Rails.cache.write(failure_key(key), error.message, expires_in: FAILURE_COOLDOWN)
      end
      raise error
    end

    Rails.logger.warn("[StaleCache] #{key}: upstream failed (#{error.message}); serving backup copy")
    Rails.cache.write(key, backup, expires_in: RETRY_AFTER)
    backup
  end

  def self.backup_key(key)
    "#{key}:backup"
  end

  def self.failure_key(key)
    "#{key}:failed"
  end

  private_class_method :fetch_fixed, :fetch_by_data, :serve_backup, :backup_key, :failure_key
end
