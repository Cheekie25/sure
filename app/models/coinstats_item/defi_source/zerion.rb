# frozen_string_literal: true

# DeFi source backed by the Zerion positions endpoint
# (GET /v1/wallets/{address}/positions/?filter[positions]=only_complex).
#
# Zerion semantics (https://developers.zerion.io/reference/listwalletpositions):
# - `attributes.value`  TOTAL position value in the requested currency (we request USD)
# - `attributes.price`  price of ONE unit of the position's asset
# - `attributes.quantity.numeric` human-readable token amount (int / 10^decimals)
# - the endpoint is not paginated and covers every chain of the address in one call
#
# One API call is made per wallet address (all chains at once) and reused for
# every blockchain linked to that address. Successful responses are also cached
# for a short time to avoid burning the "advanced" Zerion quota on repeated syncs.
class CoinstatsItem::DefiSource::Zerion
  KEY = "zerion"

  # CoinStats blockchain keys that differ from Zerion chain ids.
  CHAIN_ALIASES = {
    "arbitrum-one" => "arbitrum",
    "arbitrum_one" => "arbitrum",
    "avalanche-c-chain" => "avalanche",
    "avax" => "avalanche",
    "binance" => "binance-smart-chain",
    "binance_smart" => "binance-smart-chain",
    "binance-smart" => "binance-smart-chain",
    "bnb" => "binance-smart-chain",
    "bsc" => "binance-smart-chain",
    "eth" => "ethereum",
    "gnosis" => "xdai",
    "matic" => "polygon",
    "optimism-mainnet" => "optimism",
    "polygon-pos" => "polygon",
    "zksync" => "zksync-era"
  }.freeze

  # Zerion chains documented as supporting DeFi positions. Any other blockchain
  # is reported as unsupported instead of "no positions", so existing accounts
  # are never zeroed because of a chain mapping gap.
  SUPPORTED_CHAINS = %w[
    arbitrum avalanche base berachain binance-smart-chain blast celo ethereum fantom
    hyperevm katana linea mantle monad optimism polygon scroll soneium unichain world xdai zksync-era
  ].freeze

  # Position legs that are not imported. Loans are debts: Zerion returns them with a
  # positive value, and storing them as positive Crypto balances would overstate net worth.
  IGNORED_POSITION_TYPES = %w[loan].freeze

  DEFAULT_CACHE_TTL = 10.minutes

  # Positions worth less than this (after merging duplicates) are treated as dust
  # and not imported. Real wallets often hold dozens of near-zero protocol legs.
  DEFAULT_MIN_VALUE_USD = "1"

  def initialize(provider, cache_ttl: nil, min_value_usd: nil)
    @provider = provider
    @cache_ttl = cache_ttl || ENV.fetch("ZERION_DEFI_CACHE_TTL_SECONDS", DEFAULT_CACHE_TTL.to_i).to_i.seconds
    @min_value_usd = BigDecimal((min_value_usd || ENV.fetch("ZERION_DEFI_MIN_VALUE_USD", DEFAULT_MIN_VALUE_USD)).to_s)
    @responses = {}
  end

  def key
    KEY
  end

  # @return [CoinstatsItem::DefiSource::Result]
  def fetch(address:, blockchain:)
    normalized_blockchain = blockchain.to_s.downcase
    chain_id = self.class.zerion_chain_id(normalized_blockchain)
    unless SUPPORTED_CHAINS.include?(chain_id)
      return CoinstatsItem::DefiSource::Result.unsupported("Zerion does not support DeFi positions on #{normalized_blockchain}")
    end

    response = wallet_positions(address)
    return CoinstatsItem::DefiSource::Result.failure(response.error&.message.presence || "Zerion request failed") unless response.success?

    skipped = Hash.new(0)
    positions = response.data.filter_map do |item|
      item = item.with_indifferent_access
      next unless item.dig(:relationships, :chain, :data, :id).to_s.downcase == chain_id

      reason = skip_reason(item[:attributes])
      if reason
        skipped[reason] += 1
        next
      end

      build_position(item, normalized_blockchain, chain_id)
    end

    positions = merge_duplicates(positions).reject do |position|
      next false if position.value_usd >= @min_value_usd

      skipped["dust"] += 1
      true
    end

    CoinstatsItem::DefiSource::Result.ok(positions, skipped: skipped.to_h)
  rescue => e
    CoinstatsItem::DefiSource::Result.failure("#{e.class.name}: #{e.message}")
  end

  def self.zerion_chain_id(blockchain)
    key = blockchain.to_s.downcase.strip
    CHAIN_ALIASES.fetch(key, key)
  end

  private

    # Memoized per address for the duration of a sync, and cached across syncs
    # for @cache_ttl. Only successful responses are cached.
    def wallet_positions(address)
      address_key = address.to_s.strip.downcase
      @responses[address_key] ||= begin
        cache_key = "zerion:defi_positions:v1:#{Digest::SHA256.hexdigest(address_key)}"
        cached = @cache_ttl.positive? ? Rails.cache.read(cache_key) : nil

        if cached.is_a?(Array)
          Provider::Response.new(success?: true, data: cached, error: nil)
        else
          response = @provider.get_wallet_positions(address: address, positions: "only_complex")
          Rails.cache.write(cache_key, response.data, expires_in: @cache_ttl) if response.success? && @cache_ttl.positive?
          response
        end
      end
    end

    def skip_reason(attributes)
      attributes = attributes.to_h.with_indifferent_access
      flags = attributes[:flags].to_h.with_indifferent_access

      return "trash" if ActiveModel::Type::Boolean.new.cast(flags[:is_trash])
      return "not_displayable" if flags.key?(:displayable) && !ActiveModel::Type::Boolean.new.cast(flags[:displayable])
      return "loan" if IGNORED_POSITION_TYPES.include?(attributes[:position_type].to_s)
      return "encrypted_quantity" if attributes[:encrypted_quantity].present?
      return "zero_quantity" if quantity_for(attributes).zero?
      return "missing_symbol" if attributes.dig(:fungible_info, :symbol).blank?

      nil
    end

    def build_position(item, blockchain, chain_id)
      attributes = item[:attributes].to_h.with_indifferent_access
      fungible = attributes[:fungible_info].to_h.with_indifferent_access
      application = attributes[:application_metadata].to_h.with_indifferent_access
      dapp_id = item.dig(:relationships, :dapp, :data, :id).presence
      protocol_name = attributes[:protocol].presence || application[:name].presence
      quantity = quantity_for(attributes)
      unit_price = decimal_or_nil(attributes[:price])
      value = decimal_or_nil(attributes[:value]) || (unit_price ? quantity * unit_price : 0.to_d)
      position_type = attributes[:position_type].presence

      CoinstatsItem::DefiPosition.new(
        provider: KEY,
        account_id: "defi:zerion:#{blockchain}:#{item[:id].to_s.downcase.gsub(/\s+/, "_")}",
        blockchain: blockchain,
        provider_chain_id: chain_id,
        protocol_id: dapp_id || protocol_name.to_s.parameterize.presence,
        protocol_name: protocol_name,
        protocol_logo: application.dig(:icon, :url),
        investment_type: attributes[:protocol_module].presence,
        position_type: position_type,
        title: position_type || attributes[:name].presence,
        symbol: fungible[:symbol].to_s,
        token_name: fungible[:name],
        coin_id: item.dig(:relationships, :fungible, :data, :id) || fungible[:id],
        contract_address: contract_address_for(fungible, chain_id),
        quantity: quantity,
        unit_price_usd: unit_price || (quantity.positive? ? value / quantity : nil),
        value_usd: value,
        external_id: item[:id].to_s
      )
    end

    # Zerion can return several legs sharing the same position id (e.g. two
    # deposits of the same token in identically named pools). They are distinct
    # holdings, so sum them instead of keeping only one.
    def merge_duplicates(positions)
      positions.group_by(&:account_id).map do |_account_id, group|
        next group.first if group.one?

        quantity = group.sum(&:quantity)
        value = group.sum(&:value_usd)
        group.first.with(
          quantity: quantity,
          value_usd: value,
          unit_price_usd: group.first.unit_price_usd || (quantity.positive? ? value / quantity : nil)
        )
      end
    end

    def quantity_for(attributes)
      quantity = attributes[:quantity].to_h.with_indifferent_access
      decimal_or_nil(quantity[:numeric]) || decimal_or_nil(quantity[:float]) || 0.to_d
    end

    def contract_address_for(fungible, chain_id)
      implementation = Array(fungible[:implementations]).find do |impl|
        impl.to_h.with_indifferent_access[:chain_id].to_s == chain_id
      end
      implementation&.with_indifferent_access&.dig(:address)
    end

    def decimal_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
end
