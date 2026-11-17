# frozen_string_literal: true

# API client for the Zerion wallet data API.
# https://developers.zerion.io/
#
# This class only deals with HTTP concerns: authentication, timeouts, retries,
# error mapping and response validation. Turning Zerion positions into Sure
# accounts is the job of CoinstatsItem::DefiSource::Zerion and
# CoinstatsItem::DefiAccountManager.
#
# Authentication is HTTP Basic with the API key as username and an empty
# password. The key is never logged; wallet addresses are masked in logs.
class Provider::Zerion < Provider
  include HTTParty
  extend SslConfigurable

  Error = Class.new(Provider::Error)
  # 401 / 403: the key is missing, invalid or revoked. Retrying will not help.
  AuthenticationError = Class.new(Error)
  # 400: malformed parameters (unsupported chain, wrong address family...).
  InvalidRequestError = Class.new(Error)
  # 200 with a body that does not match the documented JSON:API shape.
  InvalidResponseError = Class.new(Error)

  # 429 after all retries, or a daily/monthly quota that is exhausted.
  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message, details: nil, retry_after: nil)
      super(message, details: details)
      @retry_after = retry_after
    end
  end

  # Internal marker for retryable 5xx responses, converted to Error after the last retry.
  class RetryableServerError < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end
  private_constant :RetryableServerError

  BASE_URL = "https://api.zerion.io"
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 30
  MAX_RETRIES = 3
  INITIAL_RETRY_DELAY = 1
  MAX_RETRY_DELAY = 15

  # Optional local daily request budget (UTC day), shared by every process through
  # Rails.cache. Set it below the plan limit, e.g. ZERION_DAILY_REQUEST_LIMIT=250
  # for a 300 requests/day key. Every HTTP attempt, retries included, counts.
  DAILY_LIMIT_ENV = "ZERION_DAILY_REQUEST_LIMIT"

  # Values accepted by `filter[positions]`.
  POSITION_FILTERS = %w[only_simple only_complex no_filter].freeze

  RETRYABLE_STATUSES = [ 429, 500, 502, 503, 504 ].freeze
  NETWORK_ERRORS = [
    SocketError, Net::OpenTimeout, Net::ReadTimeout,
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError
  ].freeze

  headers "User-Agent" => "Sure Finance Zerion Client (https://github.com/we-promise/sure)"
  default_options.merge!({ open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT }.merge(httparty_ssl_options))

  # @param api_key [String] Zerion API key
  def initialize(api_key)
    raise ArgumentError, "Zerion API key is required" if api_key.blank?

    @api_key = api_key.to_s.strip
  end

  # Lists the fungible positions of a wallet across every chain Zerion supports.
  # The endpoint is not paginated: every matching position is returned at once.
  # https://developers.zerion.io/reference/listwalletpositions
  #
  # @param address [String] EVM wallet address
  # @param positions [String] "only_complex" (DeFi protocol positions), "only_simple" or "no_filter".
  #   only_complex and no_filter count toward Zerion's "advanced" sub-quota.
  # @param chain_ids [Array<String>, nil] Optional Zerion chain ids to restrict the query to
  # @param currency [String] Valuation currency for `value` and `price`
  # @return [Provider::Response] data is the Array of JSON:API position objects (symbolized keys)
  def get_wallet_positions(address:, positions: "only_complex", chain_ids: nil, currency: "usd")
    with_provider_response do
      raise InvalidRequestError, "Wallet address is required" if address.blank?
      raise InvalidRequestError, "Unsupported positions filter: #{positions}" unless POSITION_FILTERS.include?(positions)

      query = {
        "filter[positions]" => positions,
        "filter[trash]" => "only_non_trash",
        "currency" => currency,
        "sort" => "value" # documented default: highest value first
      }
      query["filter[chain_ids]"] = Array(chain_ids).join(",") if chain_ids.present?

      payload = request(:get, "/v1/wallets/#{ERB::Util.url_encode(address.to_s.strip)}/positions/", query: query, log_label: "GET positions #{mask(address)}")
      extract_data_array!(payload)
    end
  end

  # Masks an address for logs: 0x1234...abcd
  def self.mask_address(address)
    value = address.to_s
    return value if value.length <= 10

    "#{value[0, 6]}...#{value[-4, 4]}"
  end

  private
    attr_reader :api_key

    def default_error_transformer(error)
      return error if error.is_a?(Error)

      Error.new(error.message)
    end

    def auth_headers
      {
        "Authorization" => "Basic #{Base64.strict_encode64("#{api_key}:")}",
        "Accept" => "application/json"
      }
    end

    # Performs the request and retries transient failures (429, 5xx, network)
    # with exponential backoff, honoring Retry-After / RateLimit reset headers.
    def request(method, path, query:, log_label:)
      attempts = 0

      begin
        attempts += 1
        consume_daily_budget!
        response = self.class.public_send(method, "#{BASE_URL}#{path}", headers: auth_headers, query: query)
        handle_response(response, log_label: log_label)
      rescue RateLimitError, *NETWORK_ERRORS, RetryableServerError => e
        quota_exhausted = e.is_a?(RateLimitError) && e.details.to_h[:quota_exhausted]

        if attempts <= MAX_RETRIES && !quota_exhausted
          delay = retry_delay_for(e, attempts)
          Rails.logger.warn("Zerion API: #{log_label} failed (#{e.class.name.demodulize}: #{e.message}), retry #{attempts}/#{MAX_RETRIES} in #{delay.round(2)}s")
          wait(delay)
          retry
        end

        raise translate_final_error(e)
      end
    end

    def handle_response(response, log_label:)
      case response.code
      when 200
        parse_json!(response.body)
      when 400
        log_api_error(response, log_label)
        raise InvalidRequestError.new("Zerion: invalid request - #{error_detail(response)}", details: error_details(response))
      when 401, 403
        log_api_error(response, log_label)
        raise AuthenticationError.new("Zerion: invalid or missing API key (HTTP #{response.code})", details: error_details(response))
      when 429
        log_api_error(response, log_label)
        exhausted = quota_exhausted?(response)
        remember_quota_exhausted! if exhausted
        raise RateLimitError.new(
          exhausted ? "Zerion: daily or monthly API quota exhausted" : "Zerion: rate limit exceeded",
          details: error_details(response).merge(quota_exhausted: exhausted),
          retry_after: retry_after_seconds(response)
        )
      when 500..599
        log_api_error(response, log_label)
        raise RetryableServerError.new("Zerion: server error (HTTP #{response.code})", retry_after: retry_after_seconds(response)) if RETRYABLE_STATUSES.include?(response.code)

        raise Error.new("Zerion: server error (HTTP #{response.code})", details: error_details(response))
      else
        log_api_error(response, log_label)
        raise Error.new("Zerion: unexpected response (HTTP #{response.code})", details: error_details(response))
      end
    end

    def translate_final_error(error)
      case error
      when RateLimitError then error
      when RetryableServerError then Error.new(error.message)
      else Error.new("Zerion: request failed - #{error.class.name}: #{error.message}")
      end
    end

    def parse_json!(body)
      JSON.parse(body.to_s, symbolize_names: true)
    rescue JSON::ParserError => e
      raise InvalidResponseError, "Zerion: response is not valid JSON (#{e.message.truncate(80)})"
    end

    # A successful positions response must be `{ "data": [ ... ] }`. Anything
    # else is an error, never an "empty wallet", so callers do not zero out
    # existing positions on a malformed answer.
    def extract_data_array!(payload)
      raise InvalidResponseError, "Zerion: response body is not a JSON object" unless payload.is_a?(Hash)
      raise InvalidResponseError, "Zerion: response has no `data` array" unless payload[:data].is_a?(Array)

      payload[:data].each do |item|
        unless item.is_a?(Hash) && item[:id].present? && item[:attributes].is_a?(Hash)
          raise InvalidResponseError, "Zerion: response contains a malformed position"
        end
      end

      payload[:data]
    end

    # Raises (without calling Zerion) once the local daily budget is spent, or after
    # Zerion itself reported the daily quota as exhausted earlier today.
    def consume_daily_budget!
      if Rails.cache.read(quota_exhausted_cache_key)
        raise RateLimitError.new("Zerion: daily API quota exhausted (reported earlier today)", details: { quota_exhausted: true })
      end

      limit = daily_request_limit
      return if limit.nil?

      key = "zerion:requests:#{Time.now.utc.to_date.iso8601}"
      used = Rails.cache.increment(key, 1, expires_in: 2.days)
      # Stores without atomic increment support (null/memory) return nil: fall back to read/write.
      used ||= Rails.cache.read(key).to_i.succ.tap { |value| Rails.cache.write(key, value, expires_in: 2.days) }

      return if used <= limit

      raise RateLimitError.new("Zerion: local daily request budget of #{limit} reached (#{DAILY_LIMIT_ENV})", details: { quota_exhausted: true })
    end

    def daily_request_limit
      value = ENV[DAILY_LIMIT_ENV].to_s.strip
      return nil if value.empty?

      Integer(value).clamp(0, 10_000_000)
    rescue ArgumentError
      nil
    end

    def quota_exhausted_cache_key
      "zerion:quota_exhausted:#{Time.now.utc.to_date.iso8601}"
    end

    def remember_quota_exhausted!
      Rails.cache.write(quota_exhausted_cache_key, true, expires_in: 1.day)
    end

    def quota_exhausted?(response)
      day_remaining = header_value(response, "RateLimit-Org-Day-Remaining")
      month_remaining = header_value(response, "RateLimit-Org-Month-Remaining")
      [ day_remaining, month_remaining ].compact.any? { |value| value.to_i <= 0 }
    end

    def retry_delay_for(error, attempt)
      hinted = error.respond_to?(:retry_after) ? error.retry_after : nil
      return [ hinted.to_f, MAX_RETRY_DELAY ].min if hinted.to_f.positive?

      base = INITIAL_RETRY_DELAY * (2**(attempt - 1))
      [ base + (base * rand * 0.25), MAX_RETRY_DELAY ].min
    end

    # Retry-After (seconds) is sent on 503; RateLimit-Org-Second-Reset on 429.
    def retry_after_seconds(response)
      raw = header_value(response, "Retry-After") || header_value(response, "RateLimit-Org-Second-Reset")
      return nil if raw.blank?

      Float(raw)
    rescue ArgumentError, TypeError
      nil
    end

    def header_value(response, name)
      headers = response.headers
      return nil if headers.nil?

      value = headers[name] || headers[name.downcase]
      value.is_a?(Array) ? value.first : value
    end

    def error_detail(response)
      error_details(response)[:detail].presence || "no detail"
    end

    def error_details(response)
      payload = JSON.parse(response.body.presence || "{}", symbolize_names: true)
      first = Array(payload[:errors]).first.to_h
      { status: response.code, title: first[:title], detail: first[:detail] }.compact
    rescue JSON::ParserError
      { status: response.code }
    end

    # Logs status and Zerion's error title/detail. Never logs headers (they carry the key).
    def log_api_error(response, log_label)
      details = error_details(response)
      Rails.logger.error("Zerion API: #{log_label} -> HTTP #{response.code} #{details[:title]} #{details[:detail]}".strip)
    end

    def mask(address)
      self.class.mask_address(address)
    end

    # Isolated so tests can stub it and avoid real sleeps.
    def wait(seconds)
      sleep(seconds) if seconds.to_f.positive?
    end
end
