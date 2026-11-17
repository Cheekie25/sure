# Orchestrates the sync process for a CoinStats connection.
# Imports data, processes holdings, and schedules account syncs.
class CoinstatsItem::Syncer
  include SyncStats::Collector

  attr_reader :coinstats_item

  # @param coinstats_item [CoinstatsItem] Item to sync
  def initialize(coinstats_item)
    @coinstats_item = coinstats_item
  end

  # Runs the full sync workflow: import, process, and schedule.
  # @param sync [Sync] Sync record for status tracking
  def perform_sync(sync)
    # Phase 1: Import data from CoinStats API
    sync.update!(status_text: I18n.t("models.coinstats_item.syncer.importing_wallets")) if sync.respond_to?(:status_text)
    import_result = coinstats_item.import_latest_coinstats_data

    # Phase 2: Check account setup status and collect sync statistics
    sync.update!(status_text: I18n.t("models.coinstats_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    total_accounts = coinstats_item.coinstats_accounts.count

    linked_accounts = coinstats_item.coinstats_accounts.joins(:account_provider).joins(:account).merge(Account.visible)
    unlinked_accounts = coinstats_item.coinstats_accounts.left_joins(:account_provider).where(account_providers: { id: nil })

    sync_stats = {
      total_accounts: total_accounts,
      linked_accounts: linked_accounts.count,
      unlinked_accounts: unlinked_accounts.count
    }.merge(import_health_stats(import_result))

    if unlinked_accounts.any?
      coinstats_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("models.coinstats_item.syncer.wallets_need_setup", count: unlinked_accounts.count)) if sync.respond_to?(:status_text)
    else
      coinstats_item.update!(pending_account_setup: false)
    end

    # Phase 3: Process holdings for linked accounts only
    if linked_accounts.any?
      sync.update!(status_text: I18n.t("models.coinstats_item.syncer.processing_holdings")) if sync.respond_to?(:status_text)
      coinstats_item.process_accounts

      # CoinStats provides transactions but not activity labels (Buy, Sell, Dividend, etc.)
      # Warn users that this may affect budget accuracy
      collect_investment_data_quality_warning(sync, linked_accounts, extra_details: defi_notices(import_result))

      # Phase 4: Schedule balance calculations for linked accounts
      sync.update!(status_text: I18n.t("models.coinstats_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
      coinstats_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )
    end

    if sync.respond_to?(:sync_stats)
      # Merge so stats collected earlier in this sync (data quality) are kept.
      sync.update!(sync_stats: (sync.sync_stats || {}).merge(sync_stats))
    end
  end

  # Hook called after sync completion. Currently a no-op.
  def perform_post_sync
    # no-op
  end

  private

    # Collects a data quality warning for all CoinStats accounts.
    # CoinStats cannot provide activity labels (Buy, Sell, Dividend, etc.) for transactions,
    # which may affect budget accuracy.
    def collect_investment_data_quality_warning(sync, linked_coinstats_accounts, extra_details: [])
      # All CoinStats accounts are crypto/investment accounts
      return if linked_coinstats_accounts.empty?

      collect_data_quality_stats(sync,
        warnings: linked_coinstats_accounts.size,
        notices: extra_details.size,
        details: [ {
          message: I18n.t("provider_warnings.limited_investment_data"),
          severity: "warning"
        } ] + extra_details
      )
    end

    # Translates the importer result into health stats so a sync that could not
    # refresh DeFi positions or wallet balances is not shown as fully successful.
    # The Sync itself still completes: existing balances were preserved.
    def import_health_stats(import_result)
      return {} unless import_result.is_a?(Hash)

      defi = import_result[:defi].to_h
      errors = []

      if import_result[:wallet_fetch_failed]
        errors << { "message" => I18n.t("provider_warnings.coinstats_wallet_refresh_failed"), "category" => "coinstats_wallet_sync" }
      end

      if defi[:errors].present?
        defi[:errors].each do |error|
          errors << {
            "message" => I18n.t("provider_warnings.coinstats_defi_refresh_failed_with_reason",
              provider: defi_provider_name(defi[:provider]), wallet: error[:wallet], error: error[:message]),
            "category" => "defi_sync"
          }
        end
      else
        Array(import_result[:defi_failed_wallets]).each do |wallet|
          errors << { "message" => I18n.t("provider_warnings.coinstats_defi_refresh_failed", wallet: wallet), "category" => "defi_sync" }
        end
      end

      stats = { "import_started" => true, "total_errors" => errors.size }
      stats["errors"] = errors if errors.any?
      stats["defi_sync"] = defi_summary(defi) if defi.present?

      if errors.any?
        Rails.logger.warn("CoinstatsItem::Syncer - item #{coinstats_item.id} completed with #{errors.size} error(s): #{errors.map { |e| e["category"] }.tally}")
      end

      stats
    end

    def defi_summary(defi)
      {
        "provider" => defi[:provider],
        "positions" => defi[:positions].to_i,
        "zeroed" => defi[:zeroed].to_i,
        "failed_wallets" => Array(defi[:failed_wallet_keys]).size,
        "unsupported_wallets" => defi[:unsupported].to_i,
        "skipped" => defi[:skipped].to_h,
        "inactive_provider_accounts" => defi[:inactive_provider_accounts].to_i
      }
    end

    def defi_notices(import_result)
      return [] unless import_result.is_a?(Hash)

      defi = import_result[:defi].to_h
      return [] if defi.blank?

      provider = defi_provider_name(defi[:provider])
      notices = []

      loans = defi[:skipped].to_h["loan"].to_i
      notices << { message: I18n.t("provider_warnings.coinstats_defi_loans_skipped", count: loans, provider: provider), severity: "info" } if loans.positive?

      if defi[:unsupported].to_i.positive?
        notices << { message: I18n.t("provider_warnings.coinstats_defi_unsupported_wallets", count: defi[:unsupported].to_i, provider: provider), severity: "info" }
      end

      if defi[:inactive_provider_accounts].to_i.positive?
        notices << { message: I18n.t("provider_warnings.coinstats_defi_inactive_provider_accounts", count: defi[:inactive_provider_accounts].to_i, provider: provider), severity: "warning" }
      end

      notices
    end

    def defi_provider_name(key)
      I18n.t("provider_warnings.defi_provider_names.#{key.presence || CoinstatsItem::DefiSource::DEFAULT_PROVIDER}", default: key.to_s.titleize)
    end
end
