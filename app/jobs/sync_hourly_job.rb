class SyncHourlyJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Provider item classes that opt-in to hourly syncing
  HOURLY_SYNCABLES = [
    CoinstatsItem, # https://coinstats.app/api-docs/rate-limits#plan-limits
    # Webhooks bring new Plaid transactions within minutes; this catches any that were missed.
    # /transactions/sync isn't billed per call.
    PlaidItem
  ].freeze

  def perform
    Rails.logger.info("Starting hourly sync")
    HOURLY_SYNCABLES.each do |syncable_class|
      sync_items(syncable_class)
    end
    Rails.logger.info("Completed hourly sync")
  end

  private

    def sync_items(syncable_class)
      scope = syncable_class.active
      # An item waiting for its owner to sign in again can't sync; it would only fail every hour.
      scope = scope.where(status: :good) if syncable_class == PlaidItem
      scope.find_each do |item|
        item.sync_later
      rescue => e
        Rails.logger.error("Failed to sync #{syncable_class.name} #{item.id}: #{e.message}")
      end
    end
end
