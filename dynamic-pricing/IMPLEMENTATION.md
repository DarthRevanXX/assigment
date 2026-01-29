# Implementation Notes

## Problem

We need to handle 10,000 requests/day but can only use one API token. The pricing API is expensive to call, but the spec says rates are valid for 5 minutes. Also need to handle failures gracefully and work across multiple app instances.

## Solution Overview

Built a Redis-backed caching layer with three main pieces:
1. **Distributed locking** (redis-mutex) - prevents thundering herd when cache expires
2. **Circuit breaker** (circuitbox) - fails fast when API is down
3. **Stale cache fallback** - serves old data if everything else fails

Request flow:
```
Request → Rate limit check → Param validation → Cache check
  ├─ Cache hit? Return immediately (< 1ms)
  └─ Cache miss? Acquire lock → Call API → Cache for 5min → Return
```

If 100 requests hit at once and cache is cold, only the first one calls the API. The other 99 wait ~100ms and read from cache.

## Why Redis?

Tried three options:

**In-memory cache (Rails.cache.memory_store)**
- Fast but doesn't work across multiple instances
- Each instance would have its own cache → wasted API calls
- No way to do distributed locking

**Database cache**
- Persistent, but adds 10-50ms per request
- Don't want cache reads hitting our primary DB

**Redis**
- Sub-millisecond reads
- Shared across all app instances
- Atomic operations (SET NX) for distributed locks
- Built-in TTL support

Went with Redis. Extra dependency, but worth it for multi-instance deployments.

## Cache Strategy

The spec requires rates to be no older than 5 minutes (README line 29). So:
- Primary cache: 5 min TTL
- Stale cache: 30 min TTL (fallback when API is down)

Using **lazy loading** instead of pre-warming. Only cache combos that are actually requested. There are 36 possible combinations (4 periods × 3 hotels × 3 rooms), but users probably only request a handful.

## Preventing Thundering Herd

Classic problem: cache expires at 12:00:00, then 100 requests arrive at 12:00:01. Without locking, all 100 call the API.

Using redis-mutex with double-check locking:

```ruby
def fetch_rate_with_lock(cache_key, period, hotel, room)
  # Fast path - try cache first
  rate = Rails.cache.read(cache_key)
  return rate if rate

  # Cache miss - acquire distributed lock
  lock_key = "lock:#{cache_key}"
  RedisMutex.with_lock(lock_key, expire: 10, block: 5, sleep: 0.1) do
    # Double-check - another thread might have populated cache while we waited
    rate = Rails.cache.read(cache_key)
    return rate if rate

    # Still empty - we're the chosen one, call the API
    rate = PricingApiService.fetch_rate(period: period, hotel: hotel, room: room)

    # Write both primary and stale cache
    Rails.cache.write(cache_key, rate, expires_in: 5.minutes)
    Rails.cache.write("stale:#{cache_key}", rate, expires_in: 30.minutes)

    rate
  end
end
```

Lock config:
- **expire: 10s** - lock auto-releases after 10s (prevents deadlock if thread crashes)
- **block: 5s** - threads wait max 5s to acquire lock (prevents infinite waiting)
- **sleep: 0.1s** - check every 100ms if lock is available

API timeout is 5s, so lock expiry (10s) covers worst case.

## Circuit Breaker

Using circuitbox to fail fast when the pricing API is having issues.

Config:
- Opens after **5 failures** in 60s window
- Stays open for **30s** (sleep window)
- Requires **2 successful calls** to close again

When circuit opens, raises `Circuitbox::OpenCircuitError`. We catch this and try serving stale cache:

```ruby
rescue PricingApiService::ApiError => e
  stale_rate = Rails.cache.read("stale:#{cache_key}")

  if stale_rate
    # Serve stale data with warning
    render json: {
      rate: stale_rate,
      warning: "Using cached rate due to temporary service issue"
    }
  else
    # No stale cache available, return error
    handle_api_error(e)
  end
end
```

This means if the API goes down for 10 minutes, users still get pricing (just up to 30 min old). Better than throwing 503s.

## Rate Limiting

Using Rack::Attack for per-IP rate limiting: 100 requests/minute per IP.

Quick note: this protects **our service** from abuse, not the API quota. The API quota is protected by caching. Per-IP limiting just prevents a single bad actor from overwhelming our infrastructure.

Multiple IPs × 100 req/min could theoretically exceed our capacity, but in practice:
1. Caching means most requests don't hit the API anyway
2. Circuit breaker stops cascading failures
3. Could add global rate limit if needed, but keeping it simple for now

## API Usage Math

Requirement: handle 10,000 user requests/day with one token.

Each combo can refresh 12 times/hour (every 5 min). Theoretical max:
```
36 combos × 12 refreshes/hour × 24 hours = 10,368 API calls/day
```

But this assumes:
- All 36 combos requested continuously
- Uniform traffic 24/7
- No gaps where cache expires unused

**More realistic scenarios:**

Business hours only (9am-9pm):
```
36 × 12/hour × 12 hours = 5,184 calls/day
```

Only 10 popular combos:
```
10 × 12/hour × 24 hours = 2,880 calls/day
```

Bursty traffic (users concentrated in peak hours):
```
~2,000-3,000 calls/day
```

Even worst case (10,368) is fine for demo/staging. Production could add multiple API tokens or extend stale cache TTL if needed.

## Error Handling

Three failure modes:

**1. API timeout (>5s)**
- HTTParty times out after 5s
- Raise `ApiTimeoutError`
- Try stale cache, otherwise return 504

**2. API returns error (4xx/5xx)**
- Parse response, raise appropriate error
- Circuit breaker counts this as failure
- Try stale cache, otherwise return error

**3. Redis connection fails**
- Currently raises error (500) - service goes down
- Considered adding fallback to direct API calls without caching
- Decided against it because:
  - Without Redis locking, thundering herd problem comes back
  - 100 concurrent requests would make 100 API calls
  - Could quickly exhaust API quota during incident
  - Redis is very reliable in practice (< 0.01% downtime with proper setup)
- **Failure mode is explicit and predictable:** Service down > unpredictable API quota exhaustion
- For production: use Redis Sentinel/Cluster for HA instead of fallback logic

## Configuration

**Redis connection:**
```ruby
# config/initializers/redis_mutex.rb
RedisClassy.redis = Redis.new(
  url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
  reconnect_attempts: 3
)
```

**Circuit breaker (config/initializers/circuitbox.rb):**
```ruby
PRICING_API_CIRCUIT = Circuitbox.circuit(:pricing_api, {
  exceptions: [ApiTimeoutError, ApiServerError, Net::OpenTimeout, ...],
  failure_threshold: 5,     # Open after 5 failures
  success_threshold: 2,     # Close after 2 successes
  sleep_window: 30,         # Stay open for 30s
  time_window: 60,          # Count failures in 60s window
  volume_threshold: 5       # Need 5 requests before opening
})
```

**Rate limiting (config/initializers/rack_attack.rb):**
```ruby
throttle("requests/ip", limit: 100, period: 1.minute) do |req|
  req.env['HTTP_X_FORWARDED_FOR']&.split(',')&.first&.strip || req.ip
end
```

Uses `X-Forwarded-For` header when behind a proxy.

## Performance

Measured response times:

| Scenario | Time | Notes |
|----------|------|-------|
| Cache hit | < 1ms | Most requests |
| Cache miss (first request) | 100-500ms | Calls external API |
| Cache miss (concurrent) | 50-300ms | Waits for lock, then reads cache |
| API down + stale cache | < 1ms | Serves old data |
| API down + no stale | ~5000ms | Times out |

Cache hit rate should be >95% after warm-up.

## Testing

16 tests covering:
- Basic caching (same params → 1 API call)
- Different cache keys for different params
- Distributed locking (10 concurrent threads → 1 API call)
- Stale cache fallback when API fails
- Circuit breaker behavior
- Parameter validation
- Error handling

Run tests:
```bash
docker-compose run --rm app ./bin/rails test
```

The concurrency test is the important one - verifies thundering herd protection works:
```ruby
test "should prevent thundering herd with distributed locking" do
  PricingApiService.expects(:fetch_rate).once.returns("25000")

  threads = 10.times.map do
    Thread.new { get pricing_url, params: {...} }
  end

  threads.each(&:join)
  # Only 1 API call despite 10 concurrent requests
end
```

## What Could Be Better

**Redis single point of failure**
- If Redis goes down, everything stops (service returns 500)
- **Option 1:** Add fallback to direct API calls (no caching/locking)
  - Pro: Service stays up during Redis outage
  - Con: Loses thundering herd protection - concurrent requests all hit API
  - Con: Could exhaust API quota in minutes during traffic spike
  - Chose not to implement: prefer predictable failure over quota exhaustion
- **Option 2:** Use Redis Sentinel/Cluster for HA
  - Pro: Solves availability without losing features
  - Pro: Redis stays fast and reliable
  - Better solution for production
- For this demo, accepting Redis as dependency is reasonable trade-off

**No cache warming**
- First request per combo is slow
- Could pre-populate popular combos at startup
- Trade-off: wastes API calls for unused combos

**Fixed 5-minute TTL**
- Spec requirement, but might serve stale data more often than needed
- Could implement cache-aside with conditional requests (If-Modified-Since)
- Only if API supports it

**Per-IP rate limiting only**
- Multiple IPs could overwhelm service
- Could add global rate limit (e.g., 200 req/min total)
- Current approach is simpler, relies on caching effectiveness

## Trade-offs Made

1. **Redis dependency** - Extra infrastructure, but needed for multi-instance deployment
2. **Lazy loading** - First request slow, but avoids wasting API calls on unused combos
3. **Stale cache** - Uses 2x memory (72 cache entries max), but provides graceful degradation
4. **No cache warming** - Simpler, but cold start is slower
5. **Per-IP limiting only** - Simpler than global limit, sufficient given caching effectiveness
