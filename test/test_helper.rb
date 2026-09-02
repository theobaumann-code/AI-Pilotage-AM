ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel, but capped well under the DB pool size (config/database.yml, 5 by default) —
    # :number_of_processors on a many-core dev machine spins up more worker threads than there are pooled
    # connections to hand out, and every worker over the limit hangs for 5s per test then times out.
    parallelize(workers: 2, with: :threads)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end
