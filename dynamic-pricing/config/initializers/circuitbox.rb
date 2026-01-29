require 'circuitbox'

Circuitbox.configure do |config|
  config.default_notifier = Circuitbox::Notifier::ActiveSupport
  config.default_circuit_store = Circuitbox::MemoryStore.new
end

if Rails.env.production?
  CIRCUITBOX_REDIS = Redis.new(
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    reconnect_attempts: 3
  )

  Circuitbox.configure do |config|
    config.default_circuit_store = Circuitbox::MemoryStore.new(CIRCUITBOX_REDIS)
  end
end

Rails.application.config.after_initialize do
  PRICING_API_CIRCUIT = Circuitbox.circuit(:pricing_api, {
    exceptions: [
      PricingApiService::ApiTimeoutError,
      PricingApiService::ApiServerError,
      Net::OpenTimeout,
      Net::ReadTimeout,
      SocketError
    ],
    failure_threshold: 5,
    success_threshold: 2,
    sleep_window: 30,
    time_window: 30,
    volume_threshold: 5,
    notifier: Circuitbox::Notifier::ActiveSupport.new
  })
end

ActiveSupport::Notifications.subscribe('circuit_open') do |name, start, finish, id, payload|
  Rails.logger.error(
    "[Circuit Breaker] Circuit OPEN for #{payload[:circuit]} " \
    "after #{payload[:failure_count]} failures"
  )
end

ActiveSupport::Notifications.subscribe('circuit_close') do |name, start, finish, id, payload|
  Rails.logger.info(
    "[Circuit Breaker] Circuit CLOSED for #{payload[:circuit]} " \
    "after successful recovery"
  )
end

ActiveSupport::Notifications.subscribe('circuit_success') do |name, start, finish, id, payload|
  Rails.logger.debug(
    "[Circuit Breaker] Successful request for #{payload[:circuit]}"
  )
end

ActiveSupport::Notifications.subscribe('circuit_failure') do |name, start, finish, id, payload|
  Rails.logger.warn(
    "[Circuit Breaker] Failed request for #{payload[:circuit]}: " \
    "#{payload[:exception].class} - #{payload[:exception].message}"
  )
end
