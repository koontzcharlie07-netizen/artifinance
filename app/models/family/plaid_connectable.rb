module Family::PlaidConnectable
  extend ActiveSupport::Concern

  PLAID_CREDENTIAL_SOURCES = %w[family instance].freeze

  included do
    has_many :plaid_items, dependent: :destroy
    has_one :plaid_credential, class_name: "FamilyPlaidCredential", dependent: :destroy
  end

  def can_connect_plaid_us?
    plaid(:us).present?
  end

  # If Plaid provider is configured and user is in the EU region
  def can_connect_plaid_eu?
    plaid(:eu).present? && self.eu?
  end

  # New links use the family's own keys when it has them. The instance-wide
  # keys are only for families the owner has explicitly allowed
  # (plaid_instance_keys_allowed); everyone else gets nil and is sent to the
  # Plaid keys setup page instead of silently using the owner's Plaid account.
  def plaid_credential_source
    if saved_plaid_credential
      "family"
    elsif plaid_instance_keys_allowed?
      "instance"
    end
  end

  # Shown in place of "link a bank" when the family has no usable keys.
  def needs_plaid_setup?
    plaid_credential_source.nil?
  end

  # The Plaid client for a region and key source. An item keeps the source it was
  # linked with (its access token only works with that client id), so callers
  # syncing an existing item pass its credential_source.
  def plaid_provider_for(region, credential_source: plaid_credential_source)
    case credential_source.to_s
    when "family"
      saved_plaid_credential&.provider(region)
    when "instance"
      Provider::Registry.plaid_provider_for_region(region) if plaid_instance_keys_allowed?
    end
  end

  def create_plaid_item!(public_token:, item_name:, region:)
    credential_source = plaid_credential_source
    provider = plaid(region, credential_source)
    raise PlaidItem::Provided::MissingCredentialsError, "This family has no Plaid keys" unless provider

    public_token_response = provider.exchange_public_token(public_token)

    plaid_item = plaid_items.create!(
      name: item_name,
      plaid_id: public_token_response.item_id,
      access_token: public_token_response.access_token,
      plaid_region: region,
      credential_source: credential_source,
      credential_fingerprint: credential_source == "family" ? plaid_credential.fingerprint : nil,
      owner: Current.user
    )

    plaid_item.sync_later

    plaid_item
  end

  def get_link_token(webhooks_url:, redirect_url:, accountable_type: nil, region: :us, access_token: nil, account_selection_enabled: false, credential_source: plaid_credential_source)
    provider = plaid(region, credential_source)
    return nil unless provider

    provider.get_link_token(
      user_id: self.id,
      webhooks_url: webhooks_url,
      redirect_url: redirect_url,
      accountable_type: accountable_type,
      access_token: access_token,
      account_selection_enabled: account_selection_enabled
    ).link_token
  end

  # Removes every Plaid item at Plaid before the family's data is deleted.
  # Items on the instance keys are left alone (they're shared with the owner's
  # other apps); items on the family's own keys are removed with those keys.
  # Raises on transient Plaid failures so the caller's job can retry.
  def remove_plaid_items_at_plaid!
    plaid_items.find_each(&:remove_at_plaid!)
  end

  private
    # The keys page builds an unsaved credential for its form; only saved keys count.
    def saved_plaid_credential
      plaid_credential if plaid_credential&.persisted?
    end

    def plaid(region, credential_source = plaid_credential_source)
      return nil if credential_source.nil?

      plaid_provider_for(region, credential_source: credential_source)
    end
end
