class ApplicationController < ActionController::API
  # --- Rate limiting -------------------------------------------------------------
  # One visitor (one IP address) may make REQUESTS_PER_MINUTE requests a minute to the
  # WHOLE API. Over that, they get a 429 and the request never reaches our code, so it
  # costs nothing. (The /up health check is not part of this class, so it is never limited.)
  #
  # scope: "api" makes it ONE counter for every endpoint. Without it, Rails keeps a
  # separate counter per controller, so a visitor could make 60 requests to each of them.
  #
  # The counters live in their own small in-memory store, not in Rails.cache, so a flood of
  # requests can never push cached NFL data out of the 64 MB Rails.cache (in production also
  # an in-memory store). Counts only need to live for a minute. (One Puma process means one
  # set of counters; with several processes each would count separately.)
  REQUESTS_PER_MINUTE = 60
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new(size: 2.megabytes)

  rate_limit to: REQUESTS_PER_MINUTE, within: 1.minute, scope: "api", store: RATE_LIMIT_STORE,
             with: :reject_too_many_requests

  # Every controller inherits this. If the upstream NFL API fails, don't show a
  # 500 with a stack trace: log the real reason for us, and give the client a
  # clean 502 Bad Gateway.
  rescue_from NflApiClient::Error do |error|
    Rails.logger.error("[#{self.class.name}] upstream NFL API failed: #{error.message}")
    render json: { error: "Could not load NFL data right now. Please try again later." },
           status: :bad_gateway
  end

  private

  # What a visitor over the limit gets: a clear message and a Retry-After header (seconds).
  def reject_too_many_requests
    Rails.logger.warn("[RateLimit] #{request.remote_ip} is over #{REQUESTS_PER_MINUTE} requests a minute")
    response.set_header("Retry-After", "60")
    render json: { error: "Too many requests. Please slow down and try again in a minute." },
           status: :too_many_requests
  end
end
