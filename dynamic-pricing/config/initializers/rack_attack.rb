class Rack::Attack
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    namespace: "rack_attack"
  )

  throttle("requests/ip", limit: 100, period: 1.minute) do |req|
    req.env['HTTP_X_FORWARDED_FOR']&.split(',')&.first&.strip || req.ip
  end

  self.throttled_responder = lambda do |request|
    match_data = request.env['rack.attack.match_data']
    now = Time.now.to_i
    period = match_data[:period]
    limit = match_data[:limit]
    reset_time = now + (period - (now % period))

    [
      429,
      {
        'Content-Type' => 'application/json',
        'X-RateLimit-Limit' => limit.to_s,
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset' => reset_time.to_s,
        'Retry-After' => (reset_time - now).to_s
      },
      [{
        error: "Rate limit exceeded. Maximum #{limit} requests per #{period} seconds.",
        retry_after: reset_time
      }.to_json]
    ]
  end

  safelist("allow internal health checks") do |req|
    req.path == "/health" || req.path == "/status"
  end

  ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |name, start, finish, request_id, payload|
    req = payload[:request]
    Rails.logger.warn(
      "[Rack::Attack] Throttled request from #{req.ip} to #{req.path} " \
      "(matched: #{req.env['rack.attack.matched']})"
    )
  end

  ActiveSupport::Notifications.subscribe("blocklist.rack_attack") do |name, start, finish, request_id, payload|
    req = payload[:request]
    Rails.logger.error(
      "[Rack::Attack] Blocked request from #{req.ip} to #{req.path}"
    )
  end
end
