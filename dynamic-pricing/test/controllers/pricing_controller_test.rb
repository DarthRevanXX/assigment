require "test_helper"

class PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
  end

  test "should get pricing with all parameters" do
    PricingApiService.stubs(:fetch_rate).returns("15000")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "application/json", @response.media_type
    assert_equal "15000", JSON.parse(@response.body)["rate"]
  end

  test "should cache pricing results" do
    PricingApiService.expects(:fetch_rate).once.returns("20000")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "20000", JSON.parse(@response.body)["rate"]

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "20000", JSON.parse(@response.body)["rate"]
  end

  test "should use different cache for different parameters" do
    PricingApiService.expects(:fetch_rate).with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom").returns("15000")
    PricingApiService.expects(:fetch_rate).with(period: "Winter", hotel: "GitawayHotel", room: "BooleanTwin").returns("25000")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }
    assert_equal "15000", JSON.parse(@response.body)["rate"]

    get pricing_url, params: {
      period: "Winter",
      hotel: "GitawayHotel",
      room: "BooleanTwin"
    }
    assert_equal "25000", JSON.parse(@response.body)["rate"]
  end

  test "should return error without any parameters" do
    get pricing_url

    assert_response :bad_request
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should reject invalid period" do
    get pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid room"
  end

  test "should handle API timeout errors" do
    PricingApiService.stubs(:fetch_rate).raises(PricingApiService::ApiTimeoutError, "API timeout")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :gateway_timeout
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "timeout"
  end

  test "should handle API server errors" do
    PricingApiService.stubs(:fetch_rate).raises(PricingApiService::ApiServerError, "Server error")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :service_unavailable
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Server error"
  end

  test "should handle API client errors" do
    PricingApiService.stubs(:fetch_rate).raises(PricingApiService::ApiClientError, "Invalid request")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_gateway
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid request"
  end

  test "should prevent thundering herd with distributed locking" do
    PricingApiService.expects(:fetch_rate).once.with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom").returns("25000")

    threads = 10.times.map do
      Thread.new do
        begin
          get pricing_url, params: {
            period: "Summer",
            hotel: "FloatingPointResort",
            room: "SingletonRoom"
          }
        rescue => e
        end
      end
    end

    threads.each(&:join)

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }
    assert_response :success
    assert_equal "25000", JSON.parse(@response.body)["rate"]
  end

  test "should handle concurrent requests for different parameter combinations" do
    PricingApiService.expects(:fetch_rate).once.with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom").returns("10000")
    PricingApiService.expects(:fetch_rate).once.with(period: "Winter", hotel: "GitawayHotel", room: "BooleanTwin").returns("20000")

    threads = []

    5.times do
      threads << Thread.new do
        get pricing_url, params: {
          period: "Summer",
          hotel: "FloatingPointResort",
          room: "SingletonRoom"
        }
      end
    end

    5.times do
      threads << Thread.new do
        get pricing_url, params: {
          period: "Winter",
          hotel: "GitawayHotel",
          room: "BooleanTwin"
        }
      end
    end

    threads.each(&:join)
  end

  test "should return cached rate without acquiring lock when cache is hot" do
    Rails.cache.write("rate:Summer:FloatingPointResort:SingletonRoom", "30000", expires_in: 5.minutes)
    PricingApiService.expects(:fetch_rate).never

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "30000", JSON.parse(@response.body)["rate"]
  end

  test "should populate stale cache alongside regular cache" do
    PricingApiService.stubs(:fetch_rate).returns("35000")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "35000", Rails.cache.read("rate:Summer:FloatingPointResort:SingletonRoom")
    assert_equal "35000", Rails.cache.read("stale:rate:Summer:FloatingPointResort:SingletonRoom")
  end

  test "should serve stale cache when circuit breaker is open" do
    Rails.cache.write("stale:rate:Summer:FloatingPointResort:SingletonRoom", "40000", expires_in: 30.minutes)
    PricingApiService.stubs(:fetch_rate).raises(PricingApiService::ApiServerError, "Pricing API is temporarily unavailable (circuit breaker open)")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    json_response = JSON.parse(@response.body)
    assert_equal "40000", json_response["rate"]
    assert_includes json_response["warning"], "cached rate"
  end

  test "should return error when circuit breaker is open and no stale cache" do
    PricingApiService.stubs(:fetch_rate).raises(PricingApiService::ApiServerError, "Pricing API is temporarily unavailable (circuit breaker open)")

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :service_unavailable
    assert_includes JSON.parse(@response.body)["error"].downcase, "unavailable"
  end
end
