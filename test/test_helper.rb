ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Tests run one after another on purpose. Rails switches to parallel mode at 50+
    # tests, and each parallel worker needs its own test database. This app has no
    # database tables (no db/schema.rb), so parallel mode fails. The whole suite
    # takes about 0.1 seconds, so there is nothing to gain from parallel anyway.
    parallelize(workers: 1)

    # The rate limiter's counters live in memory and would otherwise carry over from one
    # test to the next (every test makes requests from the same address).
    setup { ApplicationController::RATE_LIMIT_STORE.clear }

    # Add more helper methods to be used by all tests here...

    # The test env uses :null_store (caches nothing). Swap in a real in-memory
    # cache for the duration of the block, so caching behaviour can be tested.
    def with_memory_cache
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) { yield }
    end

    # A stand-in for NflApiClient. Counts how often it is called and either
    # returns `response` or raises it (if it is an exception).
    class FakeNflClient
      attr_reader :calls
      attr_writer :response # lets a test change the answer later, e.g. "now the API is down"

      def initialize(response)
        @response = response
        @calls = 0
      end

      def team_list
        @calls += 1
        raise @response if @response.is_a?(Exception)
        @response
      end
      alias_method :news, :team_list # same behaviour for the other endpoints
      alias_method :injuries, :team_list
      alias_method :schedule, :team_list

      # Statistics are asked for per team, so remember which team ids were requested.
      def team_statistic(team_id)
        (@team_ids ||= []) << team_id
        team_list
      end

      alias_method :team_players, :team_statistic
      alias_method :team_info, :team_statistic
      alias_method :player_overview, :team_statistic # (the id it is given is a player id here)
      alias_method :game_summary, :team_statistic  # (here it is given a game id)
      alias_method :standings, :team_statistic       # (here it is given a year)

      def team_ids = @team_ids || []

      # The chosen-week schedule: remember which [year, week] pairs were asked for.
      def schedule_for(year, week)
        (@weeks ||= []) << [ year, week ]
        team_list
      end

      def weeks = @weeks || []

      # One team's season schedule: remember which [team id, season] pairs were asked for.
      def team_schedule(team_id, season)
        (@team_seasons ||= []) << [ team_id, season ]
        team_list
      end

      def team_seasons = @team_seasons || []
    end
  end
end
