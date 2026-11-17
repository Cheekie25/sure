# frozen_string_literal: true

# Read-only diagnostics for the DeFi positions providers used by CoinStats connections.
# These tasks never write to the database: they call the provider APIs and print
# normalized positions so CoinStats and Zerion can be compared before switching.
#
#   bin/rails "coinstats_defi:compare[0xYourAddress,ethereum]"
#   bin/rails "coinstats_defi:fetch[zerion,0xYourAddress,ethereum]"
#
# Credentials: ZERION_API_KEY / Setting.zerion_api_key for Zerion;
# COINSTATS_API_KEY or the first CoinStats connection's key for CoinStats.
# Each Zerion call consumes one request of the "advanced" sub-quota, each
# CoinStats call consumes CoinStats credits.
namespace :coinstats_defi do
  desc "Print normalized DeFi positions from one provider (read-only)"
  task :fetch, [ :provider, :address, :blockchain ] => :environment do |_task, args|
    abort "Usage: bin/rails \"coinstats_defi:fetch[zerion|coinstats,0xADDRESS,ethereum]\"" if args[:provider].blank? || args[:address].blank?

    CoinstatsDefiDiagnostics.print_report(args[:provider], args[:address], args[:blockchain].presence || "ethereum")
  end

  desc "Compare CoinStats and Zerion DeFi positions for a wallet (read-only)"
  task :compare, [ :address, :blockchain ] => :environment do |_task, args|
    abort "Usage: bin/rails \"coinstats_defi:compare[0xADDRESS,ethereum]\"" if args[:address].blank?

    blockchain = args[:blockchain].presence || "ethereum"
    results = CoinstatsItem::DefiSource::PROVIDERS.index_with do |provider|
      CoinstatsDefiDiagnostics.print_report(provider, args[:address], blockchain)
    end

    puts "\n== Comparison (USD totals) =="
    results.each do |provider, result|
      total = result&.ok? ? result.positions.sum(&:value_usd) : nil
      puts format("  %-10s %s", provider, total ? format("%.2f USD (%d positions)", total, result.positions.size) : "unavailable")
    end
  end
end

module CoinstatsDefiDiagnostics
  module_function

  def print_report(provider, address, blockchain)
    puts "\n== #{provider} - #{blockchain}:#{Provider::Zerion.mask_address(address)} =="
    source = build_source(provider)
    result = source.fetch(address: address, blockchain: blockchain)

    case result.status
    when :error
      puts "  ERROR: #{result.error}"
    when :unsupported
      puts "  UNSUPPORTED: #{result.error}"
    else
      puts "  #{result.positions.size} position(s); skipped legs: #{result.skipped.presence || 'none'}"
      result.positions.each do |position|
        puts format(
          "  - %-12s %-18s %-10s qty=%-24s unit=%-14s value=%.2f USD  [%s]",
          position.symbol, position.protocol_name.to_s.truncate(18), position.position_type.to_s,
          position.quantity.to_s("F"), position.unit_price_usd&.round(4)&.to_s("F") || "n/a",
          position.value_usd, position.account_id
        )
      end
      puts "  Total: #{format('%.2f', result.positions.sum(&:value_usd))} USD"
    end

    result
  rescue CoinstatsItem::DefiSource::ConfigurationError, ArgumentError => e
    puts "  NOT CONFIGURED: #{e.message}"
    nil
  end

  def build_source(provider)
    case provider
    when "zerion"
      api_key = CoinstatsItem::DefiSource.zerion_api_key
      raise CoinstatsItem::DefiSource::ConfigurationError, "set ZERION_API_KEY or the Zerion key in Self-Hosting settings" if api_key.blank?

      CoinstatsItem::DefiSource::Zerion.new(Provider::Zerion.new(api_key), cache_ttl: 0)
    when "coinstats"
      api_key = ENV["COINSTATS_API_KEY"].presence || CoinstatsItem.where.not(api_key: nil).first&.api_key
      raise CoinstatsItem::DefiSource::ConfigurationError, "set COINSTATS_API_KEY or create a CoinStats connection" if api_key.blank?

      CoinstatsItem::DefiSource::Coinstats.new(Provider::Coinstats.new(api_key))
    else
      raise ArgumentError, "unknown provider #{provider.inspect} (expected #{CoinstatsItem::DefiSource::PROVIDERS.join(' or ')})"
    end
  end
end
