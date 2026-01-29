ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "mocha/minitest"

# Disable Rack::Attack in tests to prevent rate limiting interference
Rack::Attack.enabled = false

# Mock RedisMutex globally for tests to avoid Redis dependency
class RedisMutex
  def self.with_lock(*args)
    yield if block_given?
  end
end

class ActiveSupport::TestCase
  # Run tests in parallel with specified workers
  parallelize(workers: 1)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  # Add more helper methods to be used by all tests here...
end
