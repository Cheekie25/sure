# frozen_string_literal: true

# Simulated Zerion API payloads (JSON:API shape documented at
# https://developers.zerion.io/reference/listwalletpositions). Values are
# illustrative, not captured from a real wallet.
module ZerionTestHelper
  ZERION_TEST_ADDRESS = "0x1111111111111111111111111111111111111111"
  ZERION_POSITIONS_URL = "#{Provider::Zerion::BASE_URL}/v1/wallets/#{ZERION_TEST_ADDRESS}/positions/"

  # Lido stETH staked on Ethereum: 10 stETH, unit price 3,000 USD, total 30,000 USD.
  def zerion_steth_position(quantity: "10.0", price: 3000.0, value: 30_000.0, chain: "ethereum")
    zerion_position(
      id: "0xae7ab96520de3a18e5e111b5eaab095312d7fe84-#{chain}-staked-lido-",
      chain: chain,
      protocol: "Lido",
      dapp: "lido",
      protocol_module: "staked",
      position_type: "staked",
      symbol: "stETH",
      token_name: "Liquid staked Ether 2.0",
      fungible_id: "0xae7ab96520de3a18e5e111b5eaab095312d7fe84",
      contract: "0xae7ab96520de3a18e5e111b5eaab095312d7fe84",
      quantity: quantity,
      price: price,
      value: value
    )
  end

  def zerion_position(id:, chain:, symbol:, quantity:, price:, value:, protocol: "Aave V3", dapp: "aave-v3",
                      protocol_module: "lending", position_type: "deposit", token_name: nil, fungible_id: nil,
                      contract: nil, displayable: true, is_trash: false)
    {
      type: "positions",
      id: id,
      attributes: {
        parent: nil,
        protocol: protocol,
        protocol_module: protocol_module,
        name: "Asset",
        position_type: position_type,
        quantity: { int: "0", decimals: 18, float: quantity.to_f, numeric: quantity.to_s },
        value: value,
        price: price,
        changes: { absolute_1d: 0.0, percent_1d: 0.0 },
        fungible_info: {
          name: token_name || symbol,
          symbol: symbol,
          icon: { url: "https://cdn.zerion.io/#{symbol.downcase}.png" },
          flags: { verified: true },
          implementations: [ { chain_id: chain, address: contract, decimals: 18 } ]
        },
        flags: { displayable: displayable, is_trash: is_trash },
        updated_at: "2026-11-15T10:00:00Z",
        updated_at_block: 21_000_000,
        application_metadata: { name: protocol, icon: { url: "https://cdn.zerion.io/#{dapp}.png" }, url: "https://#{dapp}.example" }
      },
      relationships: {
        chain: { data: { type: "chains", id: chain } },
        fungible: { data: { type: "fungibles", id: fungible_id || symbol.downcase } },
        dapp: { data: { type: "dapps", id: dapp } }
      }
    }
  end

  def zerion_positions_body(*positions)
    { links: { self: ZERION_POSITIONS_URL }, data: positions }.to_json
  end

  def zerion_positions_url_pattern
    /\A#{Regexp.escape(ZERION_POSITIONS_URL)}(\?.*)?\z/
  end

  def stub_zerion_positions(status: 200, body: zerion_positions_body, headers: {})
    stub_request(:get, zerion_positions_url_pattern)
      .to_return(status: status, body: body, headers: { "Content-Type" => "application/json" }.merge(headers))
  end
end
