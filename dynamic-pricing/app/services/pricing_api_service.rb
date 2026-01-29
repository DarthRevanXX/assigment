class PricingApiService
  include HTTParty
  base_uri ENV.fetch("RATE_API_URL", "http://rate-api:3001")

  class ApiError < StandardError; end
  class ApiTimeoutError < ApiError; end
  class ApiClientError < ApiError; end
  class ApiServerError < ApiError; end

  def self.fetch_rate(period:, hotel:, room:)
    Rails.logger.info("Fetching rate from API: period=#{period}, hotel=#{hotel}, room=#{room}")

    PRICING_API_CIRCUIT.run do
      response = post("/pricing", {
        body: {
          attributes: [{ period: period, hotel: hotel, room: room }]
        }.to_json,
        headers: headers,
        timeout: 5
      })

      handle_response(response, period, hotel, room)
    end

  rescue Circuitbox::OpenCircuitError => e
    Rails.logger.error("Circuit breaker open: #{e.message}")
    raise ApiServerError, "Pricing API is temporarily unavailable (circuit breaker open)"
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    Rails.logger.error("API timeout: #{e.message}")
    raise ApiTimeoutError, "Pricing API timed out after 5 seconds"
  rescue SocketError => e
    Rails.logger.error("API connection error: #{e.message}")
    raise ApiError, "Unable to connect to pricing API"
  rescue StandardError => e
    Rails.logger.error("Unexpected API error: #{e.class} - #{e.message}")
    raise ApiError, "Pricing API error: #{e.message}"
  end

  def self.circuit_breaker
    PRICING_API_CIRCUIT
  end

  def self.circuit_breaker_status
    cb = circuit_breaker
    {
      state: cb.open? ? "OPEN" : "CLOSED",
      failure_count: cb.failure_count,
      is_open: cb.open?
    }
  end

  private

  def self.headers
    headers_hash = {
      "User-Agent" => "Tripla-Pricing-Proxy/1.0",
      "Accept" => "application/json",
      "Content-Type" => "application/json"
    }

    headers_hash["token"] = ENV["RATE_API_TOKEN"] if ENV["RATE_API_TOKEN"].present?
    headers_hash
  end

  def self.handle_response(response, period, hotel, room)
    case response.code
    when 200
      parsed = response.parsed_response

      if parsed.is_a?(Hash) && parsed["rates"].is_a?(Array) && parsed["rates"].first.present?
        rate_data = parsed["rates"].first
        if rate_data["rate"].present?
          Rails.logger.info("API returned rate: #{rate_data['rate']}")
          rate_data["rate"]
        else
          Rails.logger.error("API returned invalid response format: #{parsed.inspect}")
          raise ApiError, "Invalid response format from pricing API"
        end
      else
        Rails.logger.error("API returned invalid response format: #{parsed.inspect}")
        raise ApiError, "Invalid response format from pricing API"
      end

    when 400..499
      error_message = extract_error_message(response)
      Rails.logger.error("API client error (#{response.code}): #{error_message}")
      raise ApiClientError, "Invalid request to pricing API: #{error_message}"

    when 500..599
      error_message = extract_error_message(response)
      Rails.logger.error("API server error (#{response.code}): #{error_message}")
      raise ApiServerError, "Pricing API is temporarily unavailable"

    else
      Rails.logger.error("Unexpected API response code: #{response.code}")
      raise ApiError, "Unexpected response from pricing API (#{response.code})"
    end
  end

  def self.extract_error_message(response)
    parsed = response.parsed_response
    parsed.is_a?(Hash) && parsed["error"].present? ? parsed["error"] : "Status #{response.code}"
  rescue
    "Status #{response.code}"
  end
end
