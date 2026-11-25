Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # GET /teams                 -> TeamsController#index      (all NFL teams, cached for 7 days)
  # GET /teams/:id             -> TeamsController#show       (one team: record, venue, next game; cached for 8 hours)
  # GET /teams/:id/statistics  -> TeamsController#statistics (one team's stats, cached for 24 hours)
  # GET /teams/:id/players     -> TeamsController#players    (one team's players, cached for 24 hours)
  # GET /teams/:id/schedule    -> TeamsController#schedule   (one team's games in a season, ?season=2025; current season if left out)
  resources :teams, only: %i[index show] do
    get :statistics, on: :member
    get :players, on: :member
    get :schedule, on: :member
  end

  # GET /schedule -> ScheduleController#show (the current week's games; 2 minutes while a game is live, else up to 1 hour)
  get "schedule" => "schedule#show"

  # GET /schedule/:year/:week -> ScheduleController#week (one chosen week, e.g. /schedule/2026/10;
  # a finished week is cached for 7 days)
  get "schedule/:year/:week" => "schedule#week"

  # GET /standings       -> StandingsController#current (the current season's table)
  # GET /standings/:year -> StandingsController#show    (one season's table; both cached for 8 hours)
  get "standings" => "standings#current"
  get "standings/:year" => "standings#show"

  # GET /players/:id -> PlayersController#show (everything about one player, cached for 24 hours)
  resources :players, only: :show

  # GET /news -> NewsController#index (latest NFL news, cached for 8 hours)
  resources :news, only: :index

  # GET /games/:id -> GamesController#show (everything about one game; a finished game is cached for 30 days)
  resources :games, only: :show

  # GET /injuries -> InjuriesController#index (injury report by team, cached for 8 hours)
  resources :injuries, only: :index

  # Defines the root path route ("/")
  # root "posts#index"
end
