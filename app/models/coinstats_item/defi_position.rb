# frozen_string_literal: true

# Provider-agnostic representation of one DeFi position (one asset leg of a
# staking, lending, LP or yield position). Every DefiSource converts its
# provider's JSON into these objects, so CoinstatsItem::DefiAccountManager
# never depends on a provider's response format.
#
# Monetary semantics are explicit: `value_usd` is the TOTAL value of the
# position in USD and `unit_price_usd` is the price of ONE token in USD.
#
# @!attribute provider [String] DeFi data provider key ("coinstats", "zerion")
# @!attribute account_id [String] Stable, provider-scoped identifier used as CoinstatsAccount#account_id
# @!attribute blockchain [String] Blockchain key as stored on the linked wallet (e.g. "ethereum")
# @!attribute provider_chain_id [String, nil] Chain id in the provider's own vocabulary
# @!attribute protocol_id [String, nil] Protocol identifier (e.g. "lido")
# @!attribute protocol_name [String, nil] Protocol display name (e.g. "Lido")
# @!attribute protocol_logo [String, nil] Protocol logo URL
# @!attribute investment_type [String, nil] Provider grouping (CoinStats investment name, Zerion protocol_module)
# @!attribute position_type [String, nil] Leg type (deposit, staked, reward, locked, ...)
# @!attribute title [String, nil] Human label of the leg, used to build the account name
# @!attribute symbol [String] Token symbol (e.g. "stETH")
# @!attribute token_name [String, nil] Token display name
# @!attribute coin_id [String, nil] Provider token identifier
# @!attribute contract_address [String, nil] Token contract address on the chain (nil for native coins)
# @!attribute quantity [BigDecimal] Token amount held in the position
# @!attribute unit_price_usd [BigDecimal, nil] Price of one token in USD
# @!attribute value_usd [BigDecimal] Total position value in USD
# @!attribute external_id [String, nil] Raw provider position id, for support/debugging
CoinstatsItem::DefiPosition = Data.define(
  :provider,
  :account_id,
  :blockchain,
  :provider_chain_id,
  :protocol_id,
  :protocol_name,
  :protocol_logo,
  :investment_type,
  :position_type,
  :title,
  :symbol,
  :token_name,
  :coin_id,
  :contract_address,
  :quantity,
  :unit_price_usd,
  :value_usd,
  :external_id
) do
  def to_h
    super.transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
  end
end
