class PlayersController < ApplicationController
  # A made-up, badly formed or unknown player id is the visitor's mistake, not a server failure.
  rescue_from NflPlayerOverview::UnknownPlayer do
    render json: { error: "Player not found" }, status: :not_found
  end

  # Today's budget of new player lookups is used up (see NflPlayerOverview::DAILY_LOOKUPS).
  # Our choice, not an upstream failure: 503 with a Retry-After of the seconds until
  # midnight UTC, when the budget starts again.
  rescue_from NflApiClient::BudgetExceeded do
    now = Time.current.utc
    response.set_header("Retry-After", (now.end_of_day - now).ceil.to_s)
    render json: { error: "Player lookups are paused for today. Please try again tomorrow." },
           status: :service_unavailable
  end

  # GET /players/:id
  def show
    render json: NflPlayerOverview.for(params[:id])
  end
end
