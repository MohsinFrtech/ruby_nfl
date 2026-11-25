class TeamsController < ApplicationController
  # An id that is not one of the 32 NFL teams is the visitor's mistake, not a server failure.
  rescue_from NflTeams::UnknownTeam do
    render json: { error: "Team not found" }, status: :not_found
  end

  # GET /teams
  def index
    render json: { teams: NflTeams.all }
  end

  # A season we cannot have a schedule for (a bad or future year) is the visitor's mistake too.
  rescue_from NflTeamSchedule::UnknownSeason do
    render json: { error: "Season not found" }, status: :not_found
  end

  # GET /teams/:id/schedule  (optional ?season=2025; the current season if left out)
  def schedule
    render json: NflTeamSchedule.for(params[:id], params[:season])
  end

  # GET /teams/:id
  def show
    render json: NflTeamInfo.for(params[:id])
  end

  # GET /teams/:id/statistics
  def statistics
    render json: NflTeamStatistics.for(params[:id])
  end

  # GET /teams/:id/players
  def players
    render json: NflTeamPlayers.for(params[:id])
  end
end
