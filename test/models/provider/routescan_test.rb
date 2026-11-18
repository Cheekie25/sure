# frozen_string_literal: true

require "test_helper"

class Provider::RoutescanTest < ActiveSupport::TestCase
  BASE_URL = "https://api.routescan.io/v2/network/mainnet/evm/43114"
  ADDRESS = "0x#{"a" * 40}"
  OTHER = "0x#{"b" * 40}"
  TOKEN = "0x#{"C" * 40}"

  setup do
    @provider = Provider::Routescan.new(chain: "avalanche", base_url: BASE_URL)
    @provider.stubs(:throttle_request)
  end

  test "reads the native balance without an API key" do
    stub_action("balance", "1500")

    assert_equal "1500", @provider.native_balance(ADDRESS)
    assert_not_requested :get, /apikey/
  end

  test "lists token balances with their indexer price" do
    stub_action("addresstokenbalance", [ {
      TokenAddress: TOKEN, TokenName: "USD Coin", TokenSymbol: "USDC",
      TokenQuantity: "148349294", TokenDivisor: "6", TokenPriceUSD: "0.999532"
    } ])

    token = @provider.token_balances(ADDRESS).sole

    assert_equal TOKEN.downcase, token[:contract]
    assert_equal 6, token[:decimals]
    assert_equal "148349294", token[:raw_amount]
    assert_equal "0.999532".to_d, token[:rate]
  end

  test "an address holding only tokens has activity" do
    stub_action("balance", "0")
    stub_action("addresstokenbalance", [ { TokenAddress: TOKEN } ])

    assert @provider.has_activity?(ADDRESS)
  end

  test "an empty address has no activity" do
    stub_action("balance", "0")
    stub_action("addresstokenbalance", [])

    assert_not @provider.has_activity?(ADDRESS)
  end

  test "keeps same-token transfers of one transaction apart and skips reverted ones" do
    stub_action("txlist", [
      { hash: "0xreverted", from: OTHER, to: ADDRESS, value: "5", isError: "1", timeStamp: "1761760064" },
      { hash: "0xnative", from: OTHER, to: ADDRESS, value: "7", isError: "0", timeStamp: "1761760064" }
    ])
    transfer = { hash: "0xtoken", from: OTHER, to: ADDRESS, value: "9", contractAddress: TOKEN.downcase, tokenSymbol: "USDC", tokenDecimal: "6", timeStamp: "1761760064" }
    stub_action("tokentx", [ transfer, transfer ])

    ids = @provider.transfers(ADDRESS).map { |item| item[:external_id] }

    assert_equal [ "0xnative", "0xtoken_#{TOKEN.downcase}", "0xtoken_#{TOKEN.downcase}_2" ], ids
  end

  test "a rate limit is reported through the shared explorer errors" do
    stub_request(:get, "#{BASE_URL}/etherscan/api").with(query: hash_including({})).to_return(status: 429)
    @provider.stubs(:sleep)

    assert_raises(Provider::Etherscan::RateLimitError) { @provider.native_balance(ADDRESS) }
  end

  private
    def stub_action(action, result)
      stub_request(:get, "#{BASE_URL}/etherscan/api")
        .with(query: hash_including("action" => action, "module" => "account"))
        .to_return(json({ status: "1", message: "OK", result: result }))
    end

    def json(body)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
    end
end
