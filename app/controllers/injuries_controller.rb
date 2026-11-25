class InjuriesController < ApplicationController
  # GET /injuries
  def index
    render json: NflInjuries.latest
  end
end
