# frozen_string_literal: true

# DeFi source backed by the CoinStats `/wallet/defi` endpoint.
#
# Response shape: { protocols: [ { id, name, logo, investments: [ { name, assets: [ { coinId, symbol, title, amount, price } ] } ] } ] }
# CoinStats quirk: `asset.price` is a TotalValueDto (TOTAL position value per
# currency, e.g. { USD: 70272.0 }), not a per-token price. This class converts
# it into explicit value_usd / unit_price_usd fields.
#
# Account ids keep the historical format so existing DeFi accounts are matched
# exactly: "defi:<blockchain>:<protocol_id>[:<investment_type>]:<coin_id>:<asset_title>".
class CoinstatsItem::DefiSource::Coinstats
  KEY = "coinstats"

  def initialize(provider)
    @provider = provider
  end

  def key
    KEY
  end

  # @return [CoinstatsItem::DefiSource::Result]
  def fetch(address:, blockchain:)
    response = @provider.get_wallet_defi(address: address, connection_id: blockchain)
    return CoinstatsItem::DefiSource::Result.failure(response.error&.message.presence || "CoinStats DeFi request failed") unless response.success?

    data = response.data
    unless data.respond_to?(:to_h) && data.to_h.with_indifferent_access[:protocols].is_a?(Array)
      return CoinstatsItem::DefiSource::Result.failure("CoinStats DeFi response is missing the `protocols` array")
    end

    CoinstatsItem::DefiSource::Result.ok(normalize(data.to_h.with_indifferent_access[:protocols], blockchain.to_s.downcase))
  rescue => e
    CoinstatsItem::DefiSource::Result.failure("#{e.class.name}: #{e.message}")
  end

  private

    def normalize(protocols, blockchain)
      protocols.flat_map do |protocol|
        protocol = protocol.to_h.with_indifferent_access

        Array(protocol[:investments]).flat_map do |investment|
          investment = investment.to_h.with_indifferent_access

          Array(investment[:assets]).filter_map do |asset|
            asset = asset.to_h.with_indifferent_access
            next if asset[:amount].to_d.zero?
            next if asset[:coinId].blank? && asset[:symbol].blank?

            build_position(protocol, investment, asset, blockchain)
          end
        end
      end
    end

    def build_position(protocol, investment, asset, blockchain)
      quantity = asset[:amount].to_d
      value_usd = total_value_usd(asset[:price])

      CoinstatsItem::DefiPosition.new(
        provider: KEY,
        account_id: build_account_id(protocol, investment, asset, blockchain),
        blockchain: blockchain,
        provider_chain_id: blockchain,
        protocol_id: protocol[:id],
        protocol_name: protocol[:name],
        protocol_logo: protocol[:logo],
        investment_type: investment[:name],
        position_type: asset[:title],
        title: asset[:title],
        symbol: asset[:symbol].to_s,
        token_name: asset[:name],
        coin_id: asset[:coinId],
        contract_address: nil,
        quantity: quantity,
        unit_price_usd: quantity.positive? ? value_usd / quantity : nil,
        value_usd: value_usd,
        external_id: nil
      )
    end

    # Guard against a missing USD key falling back to the whole hash.
    def total_value_usd(price)
      raw = price.is_a?(Hash) ? price.with_indifferent_access[:USD] : price
      raw.to_d
    rescue ArgumentError, TypeError
      0.to_d
    end

    def build_account_id(protocol, investment, asset, blockchain)
      chain = blockchain.to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
      protocol_id = protocol[:id].to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
      coin_id = (asset[:coinId] || asset[:symbol]).to_s.downcase
      title = asset[:title].to_s.downcase.gsub(/\s+/, "_").presence || "position"
      investment_type = investment[:name].to_s.downcase.gsub(/\s+/, "_").presence
      parts = [ "defi", chain, protocol_id, coin_id, title ]
      parts.insert(3, investment_type) if investment_type.present?
      parts.join(":")
    end
end
