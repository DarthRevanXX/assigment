class PricingController < ApplicationController
  VALID_PERIODS = %w[Summer Autumn Winter Spring].freeze
  VALID_HOTELS = %w[FloatingPointResort GitawayHotel RecursionRetreat].freeze
  VALID_ROOMS = %w[SingletonRoom BooleanTwin RestfulKing].freeze

  before_action :validate_params

  def index
    period = params[:period]
    hotel  = params[:hotel]
    room   = params[:room]
    cache_key = "rate:#{period}:#{hotel}:#{room}"
    rate = fetch_rate_with_lock(cache_key, period, hotel, room)

    render json: { rate: rate }

  rescue PricingApiService::ApiError => e
    stale_rate = fetch_stale_cache(cache_key)

    if stale_rate
      Rails.logger.warn("API failed, serving stale cache for #{cache_key}")
      render json: {
        rate: stale_rate,
        warning: "Using cached rate due to temporary service issue"
      }
    else
      handle_api_error(e)
    end

  rescue RedisMutex::LockError
    rate = Rails.cache.read(cache_key)
    if rate
      render json: { rate: rate }
    else
      render json: { error: "Service temporarily busy, please retry" },
             status: :service_unavailable
    end
  end

  private

  def fetch_rate_with_lock(cache_key, period, hotel, room)
    rate = Rails.cache.read(cache_key)
    return rate if rate

    lock_key = "lock:#{cache_key}"
    RedisMutex.with_lock(lock_key, expire: 10, block: 5, sleep: 0.1) do
      rate = Rails.cache.read(cache_key)
      return rate if rate

      rate = PricingApiService.fetch_rate(period: period, hotel: hotel, room: room)
      Rails.cache.write(cache_key, rate, expires_in: 5.minutes)
      Rails.cache.write("stale:#{cache_key}", rate, expires_in: 30.minutes)

      rate
    end
  end

  def validate_params
    # Validate required parameters
    unless params[:period].present? && params[:hotel].present? && params[:room].present?
      return render json: { error: "Missing required parameters: period, hotel, room" }, status: :bad_request
    end

    # Validate parameter values
    unless VALID_PERIODS.include?(params[:period])
      return render json: { error: "Invalid period. Must be one of: #{VALID_PERIODS.join(', ')}" }, status: :bad_request
    end

    unless VALID_HOTELS.include?(params[:hotel])
      return render json: { error: "Invalid hotel. Must be one of: #{VALID_HOTELS.join(', ')}" }, status: :bad_request
    end

    unless VALID_ROOMS.include?(params[:room])
      return render json: { error: "Invalid room. Must be one of: #{VALID_ROOMS.join(', ')}" }, status: :bad_request
    end
  end

  def fetch_stale_cache(cache_key)
    Rails.cache.read("stale:#{cache_key}")
  rescue => e
    Rails.logger.error("Failed to fetch stale cache: #{e.message}")
    nil
  end

  def handle_api_error(error)
    case error
    when PricingApiService::ApiTimeoutError
      render json: { error: error.message }, status: :gateway_timeout
    when PricingApiService::ApiClientError
      render json: { error: error.message }, status: :bad_gateway
    when PricingApiService::ApiServerError
      render json: { error: error.message }, status: :service_unavailable
    else
      render json: { error: error.message }, status: :bad_gateway
    end
  end
end
