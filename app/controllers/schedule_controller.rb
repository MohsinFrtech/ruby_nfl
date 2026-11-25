class ScheduleController < ApplicationController
  # A year or week that cannot have a schedule is the visitor's mistake, not a server failure.
  rescue_from NflSchedule::UnknownSchedule do
    render json: { error: "Schedule not found" }, status: :not_found
  end

  # GET /schedule  (the current week)
  def show
    render json: NflSchedule.current
  end

  # GET /schedule/:year/:week  (one chosen week, e.g. /schedule/2026/10)
  def week
    render json: NflSchedule.for(params[:year], params[:week])
  end
end
