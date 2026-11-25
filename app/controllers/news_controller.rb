class NewsController < ApplicationController
  # GET /news
  def index
    render json: NflNews.latest
  end
end
