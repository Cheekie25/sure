# frozen_string_literal: true

# Keyless EVM data source for networks without a public Blockscout instance.
#
# Routescan serves an Etherscan-compatible API, so history reading is inherited;
# unlike Etherscan it also lists an address's tokens, which is what lets it be
# the only backend a network needs. Self-hosters can point a chain elsewhere
# with ROUTESCAN_<CHAIN>_URL.
class Provider::Routescan < Provider::Etherscan
  # The keyless tier allows 2 requests/second.
  MIN_REQUEST_INTERVAL = 0.6

  attr_reader :chain, :base_url

  def initialize(chain:, base_url:, max_pages: DEFAULT_MAX_PAGES, request_timeout: nil, max_retries: MAX_RETRIES)
    @chain = chain.to_s
    @base_url = ENV["ROUTESCAN_#{@chain.upcase}_URL"].presence || base_url
    @max_pages = max_pages
    @request_timeout = request_timeout
    @max_retries = max_retries
    @truncated = false
  end

  # Costs a second request only for an address with no native balance: no single
  # endpoint reports both the coin and the tokens.
  def has_activity?(address)
    native_balance(address).to_i.positive? ||
      Array(api_get(action: "addresstokenbalance", address: address, page: 1, offset: 1)).any?
  end

  def native_balance(address)
    api_get(action: "balance", address: address, tag: "latest").to_s
  end

  def token_balances(address)
    paged_get(action: "addresstokenbalance", address: address).filter_map do |token|
      contract = token["TokenAddress"].to_s.presence&.downcase
      next if contract.blank?

      {
        contract: contract,
        symbol: token["TokenSymbol"],
        name: token["TokenName"],
        decimals: token["TokenDivisor"].to_i,
        raw_amount: token["TokenQuantity"].to_s,
        market_cap: nil,
        rate: token["TokenPriceUSD"].to_s.presence&.to_d
      }
    end
  end

  private
    def api_url
      "/etherscan/api"
    end

    def authentication_params
      {}
    end

    def request_options(**options)
      options = options.merge(base_uri: base_url)
      @request_timeout ? options.merge(timeout: @request_timeout) : options
    end
end
