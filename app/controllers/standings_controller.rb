class StandingsController < ApplicationController
  # A year we cannot have standings for is the visitor's mistake, not a server failure.
  rescue_from NflStandings::UnknownStandings do
    render json: { error: "Standings not found" }, status: :not_found
  end

  # GET /standings  (the current season)
  def current
    render json: NflStandings.current
  end

  # GET /standings/:year  (e.g. /standings/2026)
  def show
    render json: NflStandings.for(params[:year])
  end
end
