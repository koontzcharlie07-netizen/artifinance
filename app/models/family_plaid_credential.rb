class FamilyPlaidCredential < ApplicationRecord
  belongs_to :family

  encrypts :client_id
  encrypts :secret
  self.filter_attributes += %i[client_id secret]
  normalizes :client_id, :secret, with: ->(value) { value.to_s.strip }

  def self.storage_available?
    ArtifinanceCore.call("plaid_credential_storage", {}, timeout: 3).fetch("available")
  end

  def self.environments
    ArtifinanceCore.call("plaid_credential_metadata", { family_id: nil }, timeout: 3).fetch("environments")
  end

  def fingerprint
    ArtifinanceCore.call("plaid_credential_fingerprint", { credential_id: id }, timeout: 3).fetch("fingerprint")
  end

  def self.fingerprint_for(client_id, environment)
    ArtifinanceCore.call(
      "plaid_credential_fingerprint_for",
      { client_id: client_id, environment: environment },
      timeout: 3
    ).fetch("fingerprint")
  end

  def verify_with_plaid
    ArtifinanceCore.call(
      "plaid_credential_verify",
      {
        credential_id: id,
        client_id: client_id,
        secret: secret,
        environment: environment
      },
      timeout: 15
    ).fetch("problem")&.to_sym
  end

  def client_id_last4
    metadata.fetch("client_id_last4")
  end

  def secret_last4
    metadata.fetch("secret_last4")
  end

  def provider(region)
    ArtifinanceCore::RemotePlaidProvider.new(
      family_id: family_id,
      region: region,
      credential_source: "family"
    )
  end

  def serializable_hash(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + %w[client_id secret]
    super(options)
  end

  private
    def metadata
      ArtifinanceCore.call("plaid_credential_metadata", { family_id: family_id }, timeout: 3)
    end
end
