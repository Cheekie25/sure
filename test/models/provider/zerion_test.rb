require "test_helper"

class Provider::ZerionTest < ActiveSupport::TestCase
  include ZerionTestHelper

  setup do
    @provider = Provider::Zerion.new("zk_test_secret")
    @provider.stubs(:wait) # no real sleeping between retries
  end

  test "requires an api key" do
    assert_raises(ArgumentError) { Provider::Zerion.new(" ") }
  end

  test "fetches complex positions with basic auth and documented query params" do
    request = stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    assert response.success?
    assert_equal 1, response.data.size
    assert_equal "stETH", response.data.first.dig(:attributes, :fungible_info, :symbol)
    assert_requested(:get, zerion_positions_url_pattern, times: 1) do |req|
      query = Rack::Utils.parse_query(req.uri.query)
      req.headers["Authorization"] == "Basic #{Base64.strict_encode64('zk_test_secret:')}" &&
        query["filter[positions]"] == "only_complex" &&
        query["currency"] == "usd" &&
        query["filter[trash]"] == "only_non_trash"
    end
    assert request
  end

  test "valid empty response is a success with no positions" do
    stub_zerion_positions(body: zerion_positions_body)

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    assert response.success?
    assert_equal [], response.data
  end

  test "401 is an authentication error and is not retried" do
    stub = stub_zerion_positions(status: 401, body: { errors: [ { title: "Unauthorized Error", detail: "The API key is invalid" } ] }.to_json)

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    refute response.success?
    assert_kind_of Provider::Zerion::AuthenticationError, response.error
    assert_requested stub, times: 1
  end

  test "429 is retried with backoff then reported as a rate limit error" do
    stub = stub_zerion_positions(status: 429, body: { errors: [ { title: "Too many requests" } ] }.to_json,
                                 headers: { "RateLimit-Org-Second-Reset" => "1", "RateLimit-Org-Day-Remaining" => "100" })

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    refute response.success?
    assert_kind_of Provider::Zerion::RateLimitError, response.error
    assert_requested stub, times: Provider::Zerion::MAX_RETRIES + 1
  end

  test "429 with an exhausted daily quota is not retried" do
    stub = stub_zerion_positions(status: 429, body: "{}", headers: { "RateLimit-Org-Day-Remaining" => "0" })

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    refute response.success?
    assert_match(/quota exhausted/, response.error.message)
    assert_requested stub, times: 1
  end

  test "500 is retried then reported as an error" do
    stub = stub_zerion_positions(status: 500, body: "Internal error")

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    refute response.success?
    assert_kind_of Provider::Zerion::Error, response.error
    assert_requested stub, times: Provider::Zerion::MAX_RETRIES + 1
  end

  test "503 while Zerion prepares data is retried and can succeed" do
    stub_request(:get, zerion_positions_url_pattern)
      .to_return({ status: 503, body: "{}", headers: { "Retry-After" => "10" } },
                 { status: 200, body: zerion_positions_body(zerion_steth_position) })
    @provider.expects(:wait).with(10.0).once

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    assert response.success?
    assert_equal 1, response.data.size
  end

  test "network timeouts are retried then reported" do
    stub = stub_request(:get, zerion_positions_url_pattern).to_timeout

    response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    refute response.success?
    assert_kind_of Provider::Zerion::Error, response.error
    assert_requested stub, times: Provider::Zerion::MAX_RETRIES + 1
  end

  test "invalid json, missing data array or malformed positions are errors, never empty wallets" do
    [ "not json", { links: {} }.to_json, { data: nil }.to_json, { data: [ { id: "x" } ] }.to_json, "" ].each do |body|
      stub_zerion_positions(body: body)

      response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

      refute response.success?, "expected failure for body #{body.inspect}"
      assert_kind_of Provider::Zerion::InvalidResponseError, response.error
      WebMock.reset!
    end
  end

  test "never logs the api key" do
    stub_zerion_positions(status: 401, body: "{}")
    logged = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(logged)

    @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

    refute_includes logged.string, "zk_test_secret"
    refute_includes logged.string, Base64.strict_encode64("zk_test_secret:")
    refute_includes logged.string, ZERION_TEST_ADDRESS
  ensure
    Rails.logger = original_logger
  end

  test "local daily budget stops calls before reaching Zerion" do
    with_memory_cache do
      ClimateControl.modify(ZERION_DAILY_REQUEST_LIMIT: "2") do
        stub = stub_zerion_positions(body: zerion_positions_body)

        2.times { assert @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS).success? }
        response = @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)

        refute response.success?
        assert_kind_of Provider::Zerion::RateLimitError, response.error
        assert_match(/daily request budget of 2/, response.error.message)
        assert_requested stub, times: 2
      end
    end
  end

  test "a quota exhausted 429 blocks further calls for the day" do
    with_memory_cache do
      stub = stub_zerion_positions(status: 429, body: "{}", headers: { "RateLimit-Org-Day-Remaining" => "0" })

      @provider.get_wallet_positions(address: ZERION_TEST_ADDRESS)
      response = Provider::Zerion.new("zk_test_secret").get_wallet_positions(address: ZERION_TEST_ADDRESS)

      refute response.success?
      assert_match(/reported earlier today/, response.error.message)
      assert_requested stub, times: 1
    end
  end

  private

    def with_memory_cache
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original
    end
end
