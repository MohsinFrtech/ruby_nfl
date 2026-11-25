class GamesController < ApplicationController
  # A made-up, badly formed or unknown game id is the visitor's mistake, not a server failure.
  rescue_from NflGameSummary::UnknownGame do
    render json: { error: "Game not found" }, status: :not_found
  end

  # Today's budget of new game lookups is used up (see NflGameSummary::DAILY_LOOKUPS).
  # Our choice, not an upstream failure: 503 with a Retry-After of the seconds until
  # midnight UTC, when the budget starts again.
  rescue_from NflApiClient::BudgetExceeded do
    now = Time.current.utc
    response.set_header("Retry-After", (now.end_of_day - now).ceil.to_s)
    render json: { error: "Game lookups are paused for today. Please try again tomorrow." },
           status: :service_unavailable
  end

  # GET /games/:id
  def show
    render json: NflGameSummary.for(params[:id])
  end
end
