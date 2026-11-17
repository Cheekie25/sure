# frozen_string_literal: true

# Manages DeFi/staking accounts for a CoinStats wallet connection.
# Positions come from a DeFi source (CoinStats or Zerion, see
# CoinstatsItem::DefiSource) as normalized CoinstatsItem::DefiPosition objects;
# this class only creates, updates and zeroes CoinstatsAccounts.
#
# Safety rules:
# - a provider error or invalid response never touches existing accounts;
# - positions missing from a complete, valid response are zeroed (never deleted);
# - zero-out is scoped to the provider that produced the response, so switching
#   between CoinStats and Zerion never zeroes the other provider's accounts.
class CoinstatsItem::DefiAccountManager
  # Outcome of one wallet sync.
  Outcome = Data.define(:status, :provider, :error, :positions_count, :zeroed_count, :skipped) do
    def success? = status == :ok
    def failed? = status == :error
    def unsupported? = status == :unsupported
  end

  attr_reader :coinstats_item

  def initialize(coinstats_item)
    @coinstats_item = coinstats_item
  end

  # Fetches DeFi positions for the given wallet and creates/updates CoinstatsAccounts.
  # @param source [#key, #fetch] a CoinstatsItem::DefiSource implementation
  # @return [Outcome]
  def sync_wallet!(address:, blockchain:, source:)
    normalized_address = address.to_s.downcase
    normalized_blockchain = blockchain.to_s.downcase

    result = source.fetch(address: address, blockchain: blockchain)

    if result.unsupported?
      Rails.logger.info "CoinstatsItem::DefiAccountManager - #{source.key} skipped #{normalized_blockchain}:#{masked(normalized_address)}: #{result.error}"
      return outcome(:unsupported, source, error: result.error)
    end

    unless result.ok?
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - DeFi fetch failed (#{source.key}) for #{normalized_blockchain}:#{masked(normalized_address)}: #{result.error}"
      return outcome(:error, source, error: result.error)
    end

    active_defi_ids = []
    had_upsert_failures = false

    # The same position can appear twice (e.g. provider duplicates); keep the first.
    result.positions.uniq(&:account_id).each do |position|
      if upsert_account!(address: normalized_address, blockchain: normalized_blockchain, position: position)
        active_defi_ids << position.account_id
      else
        had_upsert_failures = true
      end
    end

    # Skip zero-out when upserts failed: active_defi_ids is incomplete and we'd risk
    # zeroing accounts that are still active but failed to save this cycle.
    if had_upsert_failures
      return outcome(:error, source, error: "Failed to save one or more DeFi positions", positions_count: active_defi_ids.size, skipped: result.skipped)
    end

    zeroed = zero_out_inactive_accounts!(normalized_address, normalized_blockchain, active_defi_ids, provider: source.key)
    outcome(:ok, source, positions_count: active_defi_ids.size, zeroed_count: zeroed, skipped: result.skipped)
  rescue => e
    Rails.logger.warn "CoinstatsItem::DefiAccountManager - Sync failed for #{blockchain}:#{masked(address)}: #{e.class}: #{e.message}"
    outcome(:error, source, error: "#{e.class.name}: #{e.message}")
  end

  # Creates the local Account for a DeFi CoinstatsAccount if it doesn't exist yet.
  def ensure_local_account!(coinstats_account)
    return false if coinstats_account.account.present?

    account = Account.create_and_sync({
      family: coinstats_item.family,
      name: coinstats_account.name,
      balance: coinstats_account.current_balance || 0,
      cash_balance: 0,
      currency: coinstats_account.currency,
      accountable_type: "Crypto",
      accountable_attributes: {
        subtype: "wallet",
        tax_treatment: "taxable"
      }
    }, skip_initial_sync: true)

    AccountProvider.create!(account: account, provider: coinstats_account)
    true
  rescue ActiveRecord::RecordNotUnique
    # Another concurrent sync created the AccountProvider; destroy the orphaned Account we just created.
    account&.destroy
    false
  end

  # Provider that produced a DeFi CoinstatsAccount. Accounts created before
  # multi-provider support carry no marker and belong to CoinStats.
  def self.defi_provider_for(raw_payload)
    raw_payload.to_h.with_indifferent_access[:defi_provider].presence || CoinstatsItem::DefiSource::Coinstats::KEY
  end

  private

    def outcome(status, source, error: nil, positions_count: 0, zeroed_count: 0, skipped: {})
      Outcome.new(status: status, provider: source&.key, error: error, positions_count: positions_count, zeroed_count: zeroed_count, skipped: skipped || {})
    end

    def build_account_name(position)
      protocol_name = position.protocol_name.to_s
      symbol = position.symbol.to_s.upcase

      case position.title.to_s.downcase
      when "deposit", "supplied", "staked"
        "#{symbol} (#{protocol_name} Staking)"
      when "reward", "rewards", "yield"
        "#{symbol} (#{protocol_name} Rewards)"
      else
        label = position.title.to_s.presence&.then { |t| t == t.downcase ? t.titleize : t } || "Position"
        "#{symbol} (#{protocol_name} #{label})"
      end
    end

    # Returns true on success, false on failure (so the caller can track active positions correctly).
    def upsert_account!(address:, blockchain:, position:)
      coinstats_account = coinstats_item.coinstats_accounts.find_or_initialize_by(
        account_id: position.account_id,
        wallet_address: address
      )

      # Store the TOTAL position value as `balance` so inferred_current_balance uses it
      # directly instead of quantity * price, converted to the family currency.
      # convert_usd_balance returns the currency actually used: it falls back to USD
      # when no exchange rate is available.
      balance, actual_currency = convert_usd_balance(position.value_usd.to_d, family_currency)
      quantity = position.quantity.to_d
      per_token_price = quantity.positive? ? balance / quantity : 0

      snapshot = {
        source: "defi",
        defi_provider: position.provider,
        id: position.account_id,
        address: address,
        blockchain: blockchain,
        provider_chain_id: position.provider_chain_id,
        protocol_id: position.protocol_id,
        protocol_name: position.protocol_name,
        protocol_logo: position.protocol_logo,
        investment_type: position.investment_type,
        position_type: position.position_type,
        coinId: position.coin_id,
        symbol: position.symbol,
        name: position.symbol.to_s.upcase,
        contract_address: position.contract_address,
        amount: quantity.to_s("F"),
        balance: balance,
        priceUsd: per_token_price,
        value_usd: position.value_usd.to_d.to_s("F"),
        asset_title: position.title,
        currency: actual_currency,
        institution_logo: position.protocol_logo,
        external_id: position.external_id
      }.compact

      coinstats_account.name = build_account_name(position) unless coinstats_account.persisted?
      coinstats_account.currency = actual_currency
      coinstats_account.raw_payload = snapshot
      coinstats_account.current_balance = coinstats_account.inferred_current_balance(snapshot)
      coinstats_account.institution_metadata = { logo: position.protocol_logo }.compact
      coinstats_account.save!

      ensure_local_account!(coinstats_account)
      true
    rescue => e
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - Failed to upsert account #{position.account_id}: #{e.class}: #{e.message}"
      false
    end

    # Sets balance to zero for DeFi accounts of this provider no longer present in the
    # (complete and valid) API response. Accounts are kept so history is preserved.
    # @return [Integer] number of accounts zeroed
    def zero_out_inactive_accounts!(address, blockchain, active_defi_ids, provider:)
      zeroed = 0

      coinstats_item.coinstats_accounts.where(wallet_address: address).find_each do |account|
        raw = account.raw_payload.to_h.with_indifferent_access
        next unless raw[:source] == "defi"
        next unless raw[:blockchain].to_s.casecmp?(blockchain.to_s)
        next unless self.class.defi_provider_for(raw) == provider
        next if active_defi_ids.include?(account.account_id)
        next if account.current_balance.to_d.zero? && raw[:amount].to_d.zero?

        account.update!(current_balance: 0, raw_payload: raw.merge(amount: 0, balance: 0, priceUsd: 0))
        zeroed += 1
      end

      zeroed
    end

    def family_currency
      coinstats_item.family.currency.presence || "USD"
    end

    # Converts a USD amount to the target currency using Money exchange rates.
    # Returns [amount, currency] so the caller always knows what currency the amount is in.
    # Falls back to [usd_amount, "USD"] if conversion is unavailable.
    def convert_usd_balance(usd_amount, target_currency)
      return [ usd_amount, "USD" ] if target_currency == "USD" || usd_amount.zero?

      [ Money.new(usd_amount, "USD").exchange_to(target_currency).amount, target_currency ]
    rescue => e
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - FX conversion USD->#{target_currency} failed: #{e.message}"
      [ usd_amount, "USD" ]
    end

    def masked(address)
      Provider::Zerion.mask_address(address)
    end
end
