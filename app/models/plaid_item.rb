class PlaidItem < ApplicationRecord
  include Syncable, Provided, Encryptable, DestroyableLater, ProviderItemOwnable

  # A Plaid access_token only covers the institution the user authenticated
  # to through Link, so a household member may connect their own bank without
  # gaining any visibility into anyone else's connections.
  credential_scope :per_connection

  enum :plaid_region, { us: "us", eu: "eu" }
  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  validates :credential_source, inclusion: { in: Family::PlaidConnectable::PLAID_CREDENTIAL_SOURCES }

  # Encrypt sensitive credentials and raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :access_token, deterministic: true
    encrypts :raw_payload
    encrypts :raw_institution_payload
  end

  validates :name, presence: true
  validates :access_token, presence: true, on: :create

  before_destroy :remove_plaid_item

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :plaid_accounts, dependent: :destroy
  has_many :legacy_accounts, through: :plaid_accounts, source: :account

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  TRANSACTIONS_REFRESH_COOLDOWN = 5.minutes

  # Get accounts from both new and legacy systems
  def accounts
    @accounts ||= plaid_accounts
      .includes(:account, account_provider: :account)
      .map(&:current_account)
      .compact
      .uniq
  end

  def get_update_link_token(webhooks_url:, redirect_url:, account_selection_enabled: false)
    family.get_link_token(
      webhooks_url: webhooks_url,
      redirect_url: redirect_url,
      region: plaid_region,
      access_token: access_token,
      credential_source: credential_source,
      account_selection_enabled: account_selection_enabled
    )
  rescue Plaid::ApiError => e
    error_body = begin
      JSON.parse(e.response_body.to_s)
    rescue JSON::ParserError
      {}
    end

    if error_body["error_code"] == "ITEM_NOT_FOUND"
      # Mark the connection as invalid but don't auto-delete. The caller
      # gets nil so the calling controller can decide what to render.
      update!(status: :requires_update)
      Sentry.capture_exception(e) if defined?(Sentry)
      nil
    else
      # Re-raise so the controller can surface a friendly alert to the user
      # (issue #1792). Swallowing here previously left the Plaid modal frame
      # blank with no actionable signal.
      raise
    end
  end

  # Queue a fresh import after an in-flight sync. Plaid Link can finish adding
  # accounts after the active sync already fetched its account list.
  def sync_later_with_follow_up
    active_sync = syncs.visible.ordered.first
    sync_later

    return unless active_sync&.reload&.in_progress?

    PlaidFollowUpSyncJob.set(wait: PlaidFollowUpSyncJob::RETRY_DELAY).perform_later(self, active_sync_id: active_sync.id)
  end

  def request_transactions_refresh_later
    return unless supports_product?("transactions")
    return unless shared_transactions_refresh_cache?

    refresh_requested = Rails.cache.write(
      transactions_refresh_cache_key,
      true,
      expires_in: TRANSACTIONS_REFRESH_COOLDOWN,
      unless_exist: true
    )

    return unless refresh_requested

    enqueued_job = begin
      PlaidTransactionsRefreshJob.perform_later(self)
    rescue
      Rails.cache.delete(transactions_refresh_cache_key)
      raise
    end

    Rails.cache.delete(transactions_refresh_cache_key) unless enqueued_job
  end

  def sync_later_with_provider_refresh
    request_transactions_refresh_later
    sync_later_with_follow_up
  end

  def import_latest_plaid_data
    PlaidItem::Importer.new(self, plaid_provider: plaid_provider).import
  end

  # Reads the fetched data and updates internal domain objects
  # Generally, this should only be called within a "sync", but can be called
  # manually to "re-sync" the already fetched data
  def process_accounts
    plaid_accounts.each do |plaid_account|
      PlaidAccount::Processor.new(plaid_account).process
    end
  end

  # Once all the data is fetched, we can schedule account syncs to calculate historical balances
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.each do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
    end
  end

  # Saves the raw data fetched from Plaid API for this item
  def upsert_plaid_snapshot!(item_snapshot)
    assign_attributes(
      available_products: item_snapshot.available_products,
      billed_products: item_snapshot.billed_products,
      raw_payload: item_snapshot,
    )

    save!
  end

  # Linked with family keys that have since been removed or replaced by keys
  # from another Plaid account/environment. Its access token belongs to the
  # old client, so it can't sync until the bank is linked again.
  def credentials_stale?
    return false unless credential_source == "family"

    credential = family.plaid_credential
    return true unless credential&.persisted?

    credential_fingerprint.present? && credential_fingerprint != credential.fingerprint
  end

  # Tells Plaid to drop this item (stops billing, revokes the access token).
  # Instance-key items are kept (see remove_plaid_item). Errors meaning the
  # item or keys are already gone are ignored; anything else is raised when
  # raise_transient so a purge job can retry before deleting data.
  def remove_at_plaid!(raise_transient: true)
    if credential_source == "instance"
      Rails.logger.info("Artifinance: kept Plaid item #{plaid_id} at Plaid (instance keys, shared with another app)")
      return false
    end

    if credentials_stale?
      Rails.logger.warn("Artifinance: can't remove Plaid item #{plaid_id} at Plaid; the keys it was linked with are gone")
      return false
    end

    plaid_provider.remove_item(access_token)
    Rails.logger.info("Artifinance: removed Plaid item #{plaid_id} at Plaid")
    true
  rescue MissingCredentialsError
    false
  rescue Plaid::ApiError => e
    error_code = begin
      JSON.parse(e.response_body.to_s)["error_code"]
    rescue JSON::ParserError, TypeError
      nil
    end
    gone = %w[ITEM_NOT_FOUND INVALID_ACCESS_TOKEN INVALID_API_KEYS INVALID_CLIENT_ID INVALID_SECRET].include?(error_code)
    Rails.logger.warn("Failed to remove Plaid item #{plaid_id}: #{error_code || e.code}") unless gone
    raise if raise_transient && !gone
    false
  end

  # Saves the raw data fetched from Plaid API for this item's institution
  def upsert_plaid_institution_snapshot!(institution_snapshot)
    assign_attributes(
      institution_id: institution_snapshot.institution_id,
      institution_url: institution_snapshot.url,
      institution_color: institution_snapshot.primary_color,
      raw_institution_payload: institution_snapshot
    )

    save!
  end

  # Artifinance: only ask Plaid for products the item already uses (billed). Asking for an "available" one,
  # like liabilities on a card, needs consent the link may not have (Plaid then fails the whole sync) and
  # adds that product to billing.
  def supports_product?(product)
    Array(billed_products).include?(product)
  end

  private
    def transactions_refresh_cache_key
      "plaid_item:#{id}:transactions_refresh_requested"
    end

    def shared_transactions_refresh_cache?
      # Compared by name: referencing MemCacheStore autoloads it, which raises
      # LoadError without the dalli gem, and SolidCache isn't a dependency.
      shared_cache = Rails.cache.is_a?(ActiveSupport::Cache::RedisCacheStore) ||
        Rails.cache.class.name.in?(%w[ActiveSupport::Cache::MemCacheStore SolidCache::Store])

      Rails.logger.warn("Plaid transaction refresh requires a shared Rails cache store") unless shared_cache
      shared_cache
    end

    # Artifinance: items on the instance keys are shared with another local app
    # on the same client ID (~/banking-app), so /item/remove would cut it off
    # too. Those stay at Plaid. Items on a family's own keys are removed there.
    def remove_plaid_item
      remove_at_plaid!(raise_transient: false)
    end

    # Plaid splits an item's products across three arrays. If the item has made a
    # request for a product, it is put in the billed_products array. If it is
    # supported but not yet used, it goes in available_products. Products granted
    # through Link's `additional_consented_products` appear in neither -- they are
    # reported in consented_products until the first call actually bills them.
    #
    # That third array matters because it is how we request `transactions` for
    # liability accounts: Provider::Plaid#get_primary_product returns "liabilities"
    # for CreditCard/Loan, so `transactions` can only arrive as an additionally
    # consented product. Omitting it made supports_product?("transactions") false
    # for every Plaid-linked credit card, so PlaidItem::AccountsSnapshot skipped
    # the transactions fetch entirely and those accounts imported balances and
    # liabilities but no transactions at all.
    def supported_products
      consented = raw_payload.is_a?(Hash) ? Array(raw_payload["consented_products"]) : []

      (available_products + billed_products + consented).map(&:to_s).uniq
    end
end
