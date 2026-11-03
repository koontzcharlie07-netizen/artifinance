module PlaidItem::Provided
  extend ActiveSupport::Concern

  MissingCredentialsError = Class.new(StandardError)

  # Uses the keys this item was linked with: the family's own, or the instance-wide ones.
  def plaid_provider
    if credentials_stale?
      raise MissingCredentialsError, "This item was linked with Plaid keys that have since changed; link the bank again"
    end

    @plaid_provider ||= family.plaid_provider_for(plaid_region, credential_source: credential_source) ||
      raise(MissingCredentialsError, "No #{credential_source} Plaid keys are configured for this item's family")
  end
end
