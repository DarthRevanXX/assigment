require 'redis-classy'
require 'redis_mutex'

RedisClassy.redis = Redis.new(
  url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
  reconnect_attempts: 3
)
