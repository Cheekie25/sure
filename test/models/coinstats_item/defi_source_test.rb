require "test_helper"

class CoinstatsItem::DefiSourceTest < ActiveSupport::TestCase
  teardown do
    Setting.coinstats_defi_provider = "coinstats"
    Setting.zerion_api_key = nil
  end

  test "defaults to CoinStats" do
    ClimateControl.modify(COINSTATS_DEFI_PROVIDER: nil) do
      Setting.coinstats_defi_provider = nil
      assert_equal "coinstats", CoinstatsItem::DefiSource.configured_provider
      assert_kind_of CoinstatsItem::DefiSource::Coinstats, CoinstatsItem::DefiSource.build(coinstats_provider: mock)
    end
  end

  test "environment variable overrides the setting and unknown values fall back to CoinStats" do
    Setting.coinstats_defi_provider = "coinstats"
    ClimateControl.modify(COINSTATS_DEFI_PROVIDER: "zerion") do
      assert_equal "zerion", CoinstatsItem::DefiSource.configured_provider
    end
    ClimateControl.modify(COINSTATS_DEFI_PROVIDER: "debank") do
      assert_equal "coinstats", CoinstatsItem::DefiSource.configured_provider
    end
  end

  test "building Zerion without a key raises a configuration error instead of falling back" do
    ClimateControl.modify(ZERION_API_KEY: nil, COINSTATS_DEFI_PROVIDER: nil) do
      Setting.coinstats_defi_provider = "zerion"
      assert_raises(CoinstatsItem::DefiSource::ConfigurationError) do
        CoinstatsItem::DefiSource.build(coinstats_provider: mock)
      end
    end
  end

  test "Zerion API key is stored encrypted" do
    Setting.zerion_api_key = "zk_secret_value"

    assert_equal "zk_secret_value", Setting.zerion_api_key
    raw = Setting.find_by(var: "zerion_api_key")&.read_attribute(:value)
    refute_includes raw.to_s, "zk_secret_value"
  end

  test "CoinStats source converts total value into explicit value and unit price" do
    provider = mock
    provider.expects(:get_wallet_defi).returns(Provider::Response.new(success?: true, error: nil, data: {
      protocols: [ { id: "lido", name: "Lido", investments: [ { name: "Staking", assets: [
        { coinId: "ethereum", symbol: "ETH", title: "Deposit", amount: 32, price: { USD: 70_272.0 } }
      ] } ] } ]
    }))

    result = CoinstatsItem::DefiSource::Coinstats.new(provider).fetch(address: "0xabc", blockchain: "ethereum")

    assert result.ok?
    position = result.positions.sole
    assert_equal "defi:ethereum:lido:staking:ethereum:deposit", position.account_id
    assert_equal BigDecimal("70272"), position.value_usd
    assert_equal BigDecimal("2196"), position.unit_price_usd
  end

  test "CoinStats response without a protocols array is an error, not an empty wallet" do
    [ {}, { protocols: nil }, nil, "unexpected" ].each do |data|
      provider = mock
      provider.expects(:get_wallet_defi).returns(Provider::Response.new(success?: true, error: nil, data: data))

      result = CoinstatsItem::DefiSource::Coinstats.new(provider).fetch(address: "0xabc", blockchain: "ethereum")

      assert result.error?, "expected error for #{data.inspect}"
    end
  end

  test "Zerion source reports unsupported chains without calling the API" do
    provider = mock
    provider.expects(:get_wallet_positions).never

    result = CoinstatsItem::DefiSource::Zerion.new(provider, cache_ttl: 0).fetch(address: "0xabc", blockchain: "tron")

    assert result.unsupported?
  end

  test "Zerion source maps CoinStats chain aliases" do
    assert_equal "binance-smart-chain", CoinstatsItem::DefiSource::Zerion.zerion_chain_id("bsc")
    assert_equal "arbitrum", CoinstatsItem::DefiSource::Zerion.zerion_chain_id("arbitrum-one")
    assert_equal "ethereum", CoinstatsItem::DefiSource::Zerion.zerion_chain_id("Ethereum")
  end

  test "Zerion source sums legs sharing a position id and skips dust" do
    include_helper = Object.new.extend(ZerionTestHelper)
    pool_id = "0x6b175474e89094c44da98b954eedeac495271d0f-ethereum-balancer v2 dai/usdc/usdt pool-deposit"
    legs = [
      include_helper.zerion_position(id: pool_id, chain: "ethereum", symbol: "DAI", quantity: "600", price: 1.0, value: 600.0, protocol: "Balancer V2", dapp: "balancer-v2"),
      include_helper.zerion_position(id: pool_id, chain: "ethereum", symbol: "DAI", quantity: "400", price: 1.0, value: 400.0, protocol: "Balancer V2", dapp: "balancer-v2"),
      include_helper.zerion_position(id: "dust-leg", chain: "ethereum", symbol: "BARK", quantity: "497564738", price: 0.0, value: 0.0)
    ]
    provider = mock
    provider.expects(:get_wallet_positions).once.returns(Provider::Response.new(success?: true, error: nil, data: JSON.parse(legs.to_json, symbolize_names: true)))

    result = CoinstatsItem::DefiSource::Zerion.new(provider, cache_ttl: 0).fetch(address: "0xabc", blockchain: "ethereum")

    position = result.positions.sole
    assert_equal "defi:zerion:ethereum:0x6b175474e89094c44da98b954eedeac495271d0f-ethereum-balancer_v2_dai/usdc/usdt_pool-deposit", position.account_id
    assert_equal BigDecimal("1000"), position.quantity
    assert_equal BigDecimal("1000"), position.value_usd
    assert_equal({ "dust" => 1 }, result.skipped)
  end
end
