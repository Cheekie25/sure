require "test_helper"

# End-to-end DeFi refresh through the Zerion provider with simulated HTTP
# responses: Importer -> DefiSource::Zerion -> Provider::Zerion -> DefiAccountManager.
class CoinstatsItem::ZerionDefiSyncTest < ActiveSupport::TestCase
  include ZerionTestHelper

  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(family: @family, name: "CoinStats", api_key: "coinstats_key")

    Setting.coinstats_defi_provider = "zerion"
    Setting.zerion_api_key = "zk_test_secret"
    Provider::Zerion.any_instance.stubs(:wait)

    # CoinStats still serves wallet balances and transactions.
    @coinstats_provider = mock("Provider::Coinstats")
    @coinstats_provider.stubs(:get_wallet_balances).returns(Provider::Response.new(success?: true, data: [], error: nil))
    @coinstats_provider.stubs(:extract_wallet_balance).returns([])
    @coinstats_provider.stubs(:get_wallet_transactions).returns(Provider::Response.new(success?: true, data: [], error: nil))
    @coinstats_provider.stubs(:extract_wallet_transactions).returns([])
    @coinstats_provider.expects(:get_wallet_defi).never

    link_wallet!
  end

  teardown do
    Setting.coinstats_defi_provider = "coinstats"
    Setting.zerion_api_key = nil
  end

  test "creates a Lido stETH account valued with the total position value" do
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))

    result = import!

    assert result[:success]
    account = defi_accounts.sole
    assert_equal "defi:zerion:ethereum:0xae7ab96520de3a18e5e111b5eaab095312d7fe84-ethereum-staked-lido-", account.account_id
    assert_equal "STETH (Lido Staking)", account.name
    assert_equal 30_000.0, account.current_balance.to_f
    assert_equal "USD", account.currency
    assert_equal "zerion", account.raw_payload["defi_provider"]
    assert_equal "lido", account.raw_payload["protocol_id"]
    assert_equal "10.0", account.raw_payload["amount"]
    assert_equal 3000.0, account.raw_payload["priceUsd"].to_f
    assert_equal "0xae7ab96520de3a18e5e111b5eaab095312d7fe84", account.raw_payload["contract_address"]
    assert account.account.present?, "a local Crypto account is created"
    assert_equal 1, result[:defi][:positions]
  end

  test "converts the USD value to the family currency" do
    @family.update!(currency: "EUR")
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))

    import!

    account = defi_accounts.sole
    assert_equal "EUR", account.currency
    assert_in_delta 27_000.0, account.current_balance.to_f, 0.001
    assert_in_delta 2_700.0, account.raw_payload["priceUsd"].to_f, 0.001 # per-token price in family currency
  end

  test "repeated syncs update the same account without duplicates" do
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))
    import!

    WebMock.reset!
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position(quantity: "11.0", value: 33_000.0)))

    assert_no_difference -> { CoinstatsAccount.count } do
      assert_no_difference -> { Account.count } do
        import!
      end
    end
    assert_equal 33_000.0, defi_accounts.sole.current_balance.to_f
  end

  test "a wallet without DeFi positions is a success and creates nothing" do
    stub_zerion_positions(body: zerion_positions_body)

    result = import!

    assert result[:success]
    assert_empty defi_accounts
    assert_empty result[:defi][:errors]
  end

  test "ignores loans, spam, other chains and keeps one call per address" do
    loan = zerion_position(id: "usdc-loan", chain: "ethereum", symbol: "USDC", quantity: "500", price: 1.0, value: 500.0, position_type: "loan")
    spam = zerion_position(id: "spam", chain: "ethereum", symbol: "SCAM", quantity: "1", price: 1.0, value: 1.0, is_trash: true)
    arbitrum = zerion_steth_position(chain: "arbitrum")
    request = stub_zerion_positions(body: zerion_positions_body(zerion_steth_position, loan, spam, arbitrum))

    result = import!

    assert_equal [ "STETH (Lido Staking)" ], defi_accounts.map(&:name)
    assert_equal 1, result[:defi][:skipped]["loan"]
    assert_equal 1, result[:defi][:skipped]["trash"]
    assert_requested request, times: 1
  end

  { 401 => "invalid key", 429 => "rate limit", 500 => "server error" }.each do |status, label|
    test "HTTP #{status} (#{label}) preserves existing positions and reports a DeFi error" do
      stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))
      import!
      account = defi_accounts.sole

      WebMock.reset!
      stub_zerion_positions(status: status, body: { errors: [ { title: label } ] }.to_json)
      result = import!

      account.reload
      assert_equal 30_000.0, account.current_balance.to_f
      assert_equal "10.0", account.raw_payload["amount"]
      refute result[:success]
      assert_equal 1, result[:defi][:errors].size
      assert_includes result[:defi][:failed_wallet_keys], "ethereum:#{ZERION_TEST_ADDRESS}"
    end
  end

  test "an invalid response preserves existing positions" do
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))
    import!

    [ "", "<html>", { data: nil }.to_json ].each do |body|
      WebMock.reset!
      stub_zerion_positions(body: body)
      result = import!

      refute result[:success], "body #{body.inspect} must be treated as an error"
      assert_equal 30_000.0, defi_accounts.sole.reload.current_balance.to_f
    end
  end

  test "zeroes a Zerion position that disappeared from a complete valid response" do
    aave = zerion_position(id: "usdc-aave-deposit", chain: "ethereum", symbol: "USDC", quantity: "1000", price: 1.0, value: 1000.0)
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position, aave))
    import!
    assert_equal 2, defi_accounts.count

    WebMock.reset!
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))
    result = import!

    usdc = defi_accounts.find { |a| a.raw_payload["symbol"] == "USDC" }
    assert_equal 0, usdc.current_balance.to_f
    assert_equal 30_000.0, defi_accounts.find { |a| a.raw_payload["symbol"] == "stETH" }.current_balance.to_f
    assert_equal 1, result[:defi][:zeroed]
    assert_equal 2, defi_accounts.count, "accounts are zeroed, never deleted"
  end

  test "never zeroes DeFi accounts created by CoinStats and reports them as not refreshed" do
    legacy = create_linked_defi_account!(
      account_id: "defi:ethereum:lido:staking:ethereum:deposit",
      raw_payload: { source: "defi", address: ZERION_TEST_ADDRESS, blockchain: "ethereum", amount: 10, balance: 29_000 },
      balance: 29_000
    )
    stub_zerion_positions(body: zerion_positions_body)

    result = import!

    assert_equal 29_000.0, legacy.reload.current_balance.to_f
    assert_equal 1, result[:defi][:inactive_provider_accounts]
  end

  test "Zerion selected without an API key reports an error and touches nothing" do
    stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))
    import!
    Setting.zerion_api_key = nil

    WebMock.reset!
    result = import!

    refute result[:success]
    assert_match(/no Zerion API key/, result[:defi][:errors].first[:message])
    assert_equal 30_000.0, defi_accounts.sole.reload.current_balance.to_f
    assert_not_requested :get, zerion_positions_url_pattern
  end

  test "successful responses are cached to save quota" do
    with_memory_cache do
      request = stub_zerion_positions(body: zerion_positions_body(zerion_steth_position))

      import!
      import!

      assert_requested request, times: 1
    end
  end

  test "syncer surfaces DeFi errors in sync stats while the sync completes" do
    stub_zerion_positions(status: 500, body: "{}")
    CoinstatsItem.any_instance.stubs(:coinstats_provider).returns(@coinstats_provider)
    CoinstatsItem.any_instance.stubs(:schedule_account_syncs).returns([]) # no child syncs to wait for
    sync = Sync.create!(syncable: @coinstats_item)

    sync.perform
    sync.reload

    assert sync.completed?, "status=#{sync.status} error=#{sync.error.inspect}"
    assert_equal 1, sync.sync_stats["total_errors"]
    assert_equal "defi_sync", sync.sync_stats["errors"].first["category"]
    assert_match(/Zerion/, sync.sync_stats["errors"].first["message"])
    refute_includes sync.sync_stats.to_json, ZERION_TEST_ADDRESS
    assert_equal "zerion", sync.sync_stats["defi_sync"]["provider"]
    assert @coinstats_item.reload.latest_sync_incomplete?
  end

  private

    def import!
      CoinstatsItem::Importer.new(@coinstats_item.reload, coinstats_provider: @coinstats_provider).import
    end

    def defi_accounts
      @coinstats_item.coinstats_accounts.reload.select(&:defi_source?)
    end

    def link_wallet!
      account = @family.accounts.create!(accountable: Crypto.create!, name: "Ethereum Wallet", balance: 0, currency: "USD")
      wallet = @coinstats_item.coinstats_accounts.create!(
        name: "Ethereum", currency: "USD", account_id: "ethereum",
        raw_payload: { address: ZERION_TEST_ADDRESS, blockchain: "ethereum" }
      )
      AccountProvider.create!(account: account, provider: wallet)
    end

    def create_linked_defi_account!(account_id:, raw_payload:, balance:)
      account = @family.accounts.create!(accountable: Crypto.create!, name: "Legacy DeFi", balance: balance, currency: "USD")
      defi = @coinstats_item.coinstats_accounts.create!(
        name: "ETH (Lido Staking)", currency: "USD", account_id: account_id,
        wallet_address: ZERION_TEST_ADDRESS.downcase, current_balance: balance, raw_payload: raw_payload
      )
      AccountProvider.create!(account: account, provider: defi)
      defi
    end

    def with_memory_cache
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original
    end
end
