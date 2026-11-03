module Family::PlaidConnectable
  extend ActiveSupport::Concern

  PLAID_CREDENTIAL_SOURCES = %w[family instance].freeze

  included do
    has_many :plaid_items, dependent: :destroy
    has_one :plaid_credential, class_name: "FamilyPlaidCredential", dependent: :destroy
  end

  def can_connect_plaid_us?
    !needs_plaid_setup?
  end

  def can_connect_plaid_eu?
    !needs_plaid_setup? && eu?
  end

  def plaid_credential_source
    ArtifinanceCore.call("plaid_credential_source", { family_id: id }, timeout: 3).fetch("source")
  end

  def needs_plaid_setup?
    plaid_credential_source.nil?
  end

  def plaid_provider_for(region, credential_source: plaid_credential_source)
    return if credential_source.blank?
    available = ArtifinanceCore.call(
      "plaid_provider_available",
      { family_id: id, region: region, credential_source: credential_source },
      timeout: 5
    ).fetch("available")
    return unless available

    ArtifinanceCore::RemotePlaidProvider.new(
      family_id: id,
      region: region,
      credential_source: credential_source
    )
  end

  def create_plaid_item!(public_token:, item_name:, region:)
    result = ArtifinanceCore.call(
      "plaid_create_item",
      { family_id: id, user_id: Current.user&.id, public_token: public_token, item_name: item_name, region: region },
      timeout: 30
    )
    plaid_items.find(result.fetch("item_id"))
  rescue ArtifinanceCore::Dispatcher::InvalidRequest, ArtifinanceCore::RemoteError => error
    raise unless error.message.include?("no Plaid keys")

    raise PlaidItem::Provided::MissingCredentialsError, error.message
  end

  def get_link_token(webhooks_url:, redirect_url:, accountable_type: nil, region: :us, access_token: nil, account_selection_enabled: false, credential_source: plaid_credential_source)
    ArtifinanceCore.call(
      "plaid_link_token",
      {
        family_id: id,
        webhooks_url: webhooks_url,
        redirect_url: redirect_url,
        accountable_type: accountable_type,
        region: region,
        access_token: access_token,
        account_selection_enabled: account_selection_enabled,
        credential_source: credential_source
      },
      timeout: 30
    ).fetch("link_token")
  end

  def remove_plaid_items_at_plaid!
    ArtifinanceCore.call("plaid_remove_family_items", { family_id: id }, timeout: 60)
  end
end
