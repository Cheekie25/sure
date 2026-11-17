# frozen_string_literal: true

# Selects and builds the DeFi data source used to refresh DeFi/staking
# positions of a CoinStats connection.
#
# A DeFi source answers one question: "what are the DeFi positions of this
# wallet on this blockchain?" and returns a Result made of normalized
# CoinstatsItem::DefiPosition objects. Adding a provider (e.g. DeBank) means
# adding a class that implements `key` and `fetch(address:, blockchain:)`.
#
# The provider is chosen by the instance administrator:
#   1. ENV["COINSTATS_DEFI_PROVIDER"] when set
#   2. Setting.coinstats_defi_provider (Self-Hosting settings page)
#   3. "coinstats" (default, unchanged behavior)
# There is deliberately no automatic fallback between providers.
module CoinstatsItem::DefiSource
  PROVIDERS = %w[coinstats zerion].freeze
  DEFAULT_PROVIDER = "coinstats"

  # Outcome of a fetch for one wallet.
  # - :ok           the provider answered with a complete, valid response (positions may be empty)
  # - :error        the provider failed; existing positions must be preserved
  # - :unsupported  the provider cannot serve this blockchain; nothing to do, nothing to zero
  Result = Data.define(:status, :positions, :error, :skipped) do
    def self.ok(positions, skipped: {}) = new(status: :ok, positions: positions, error: nil, skipped: skipped)
    def self.failure(error) = new(status: :error, positions: [], error: error, skipped: {})
    def self.unsupported(reason) = new(status: :unsupported, positions: [], error: reason, skipped: {})

    def ok? = status == :ok
    def error? = status == :error
    def unsupported? = status == :unsupported
  end

  # Raised by a source that cannot be used (e.g. Zerion selected without an API key).
  ConfigurationError = Class.new(StandardError)

  class << self
    # @return [String] the configured provider key, normalized to a known value
    def configured_provider
      raw = ENV["COINSTATS_DEFI_PROVIDER"].presence || Setting.coinstats_defi_provider.presence || DEFAULT_PROVIDER
      value = raw.to_s.strip.downcase
      return value if PROVIDERS.include?(value)

      Rails.logger.warn("CoinstatsItem::DefiSource - Unknown DeFi provider #{value.inspect}, using #{DEFAULT_PROVIDER}")
      DEFAULT_PROVIDER
    end

    # @return [String, nil] Zerion API key from ENV or encrypted Setting
    def zerion_api_key
      ENV["ZERION_API_KEY"].presence || Setting.zerion_api_key.presence
    end

    # Builds the source for the configured provider.
    # @param coinstats_provider [Provider::Coinstats] client used by the CoinStats source
    # @param provider_key [String, nil] override, used by the comparison task
    # @raise [ConfigurationError] when the selected provider is not usable
    def build(coinstats_provider:, provider_key: nil)
      case provider_key || configured_provider
      when "zerion"
        api_key = zerion_api_key
        raise ConfigurationError, "Zerion is selected as DeFi provider but no Zerion API key is configured" if api_key.blank?

        CoinstatsItem::DefiSource::Zerion.new(Provider::Zerion.new(api_key))
      else
        CoinstatsItem::DefiSource::Coinstats.new(coinstats_provider)
      end
    end
  end
end
