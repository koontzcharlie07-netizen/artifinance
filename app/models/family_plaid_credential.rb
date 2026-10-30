# A family's own Plaid API keys. When present, they are used for that family's
# new Plaid links and for syncing the items linked with them. Families without
# one can't link banks (unless the owner allowed them the instance keys).
#
# Both keys are encrypted at rest with Active Record encryption and are never
# rendered back in full: the UI only shows the last four characters.
class FamilyPlaidCredential < ApplicationRecord
  ENVIRONMENTS = %w[sandbox production].freeze

  belongs_to :family

  encrypts :client_id
  encrypts :secret

  self.filter_attributes += %i[client_id secret]

  normalizes :client_id, :secret, with: ->(value) { value.to_s.strip }

  validates :client_id, :secret, presence: true
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :family_id, uniqueness: true
  validate :encryption_keys_come_from_env

  # Encryption keys must come from the environment in production so the keys
  # protecting these secrets never live in the repo or in the database itself.
  def self.storage_available?
    !Rails.env.production? || ActiveRecordEncryptionConfig.complete_env?
  end

  # Identifies which Plaid account + environment these keys belong to, without
  # storing the keys again. Items remember the fingerprint they were linked with.
  def fingerprint
    self.class.fingerprint_for(client_id, environment)
  end

  def self.fingerprint_for(client_id, environment)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{client_id.to_s.strip}:#{environment}").first(32)
  end

  # Makes a cheap authenticated call to Plaid with these keys. Returns nil when
  # Plaid accepts them, or an error key (for i18n) describing what's wrong.
  def verify_with_plaid
    provider(:us).client.institutions_get(
      Plaid::InstitutionsGetRequest.new(count: 1, offset: 0, country_codes: [ "US" ])
    )
    nil
  rescue Plaid::ApiError => e
    code = begin
      JSON.parse(e.response_body.to_s)["error_code"]
    rescue JSON::ParserError, TypeError
      nil
    end
    Rails.logger.info("Plaid key check failed: #{code || e.code}")
    case code
    # INVALID_FIELD: the request is fixed, so a malformed client id or secret.
    when "INVALID_API_KEYS", "INVALID_CLIENT_ID", "INVALID_SECRET", "INVALID_FIELD" then :invalid_keys
    when "UNAUTHORIZED_ENVIRONMENT" then :unauthorized_environment
    else :plaid_error
    end
  rescue Faraday::Error, Timeout::Error, SocketError, OpenSSL::SSL::SSLError
    :unreachable
  end

  def client_id_last4
    client_id.to_s.last(4)
  end

  def secret_last4
    secret.to_s.last(4)
  end

  def provider(region)
    Provider::Plaid.new(plaid_configuration, region: region.to_sym)
  end

  # Keep the keys out of JSON/exports even if a record is serialized by accident.
  def serializable_hash(options = nil)
    options = (options || {}).dup
    options[:except] = Array(options[:except]) + %w[client_id secret]
    super(options)
  end

  private
    def plaid_configuration
      Plaid::Configuration.new.tap do |config|
        config.server_index = Plaid::Configuration::Environment[environment]
        config.api_key["PLAID-CLIENT-ID"] = client_id
        config.api_key["PLAID-SECRET"] = secret
      end
    end

    def encryption_keys_come_from_env
      return if self.class.storage_available?

      errors.add(:base, :encryption_not_configured)
    end
end
