# Saves a family's Plaid keys from a forgiving paste. Each candidate secret is tried with Plaid in Production
# first, then Sandbox, so nobody has to know which kind they copied. The first pair Plaid accepts is saved.
class PlaidKeySetup
  ENVIRONMENTS = %w[production sandbox].freeze

  Result = Struct.new(:status, :environment, keyword_init: true) do
    def saved? = status == :saved
  end

  def initialize(family, text)
    @family = family
    @paste = PlaidKeyPaste.new(text)
  end

  def call
    return Result.new(status: @paste.problem) unless @paste.complete?

    outcomes = []
    @paste.secrets.each do |secret|
      ENVIRONMENTS.each do |environment|
        outcome = try(client_id: @paste.client_ids.first, secret: secret, environment: environment)
        return Result.new(status: :saved, environment: environment) if outcome == :saved
        return Result.new(status: outcome) if outcome == :unreachable

        outcomes << outcome
      end
    end
    Result.new(status: outcomes.include?(:plaid_unauthorized_environment) ? :not_approved : :rejected)
  end

  private
    def try(client_id:, secret:, environment:)
      result = ArtifinanceCore.call(
        "plaid_credential_update",
        { family_id: @family.id, attributes: { client_id: client_id, secret: secret, environment: environment }, confirm_relink: false },
        timeout: 30
      )
      return :saved if result.fetch("saved")

      code = result.fetch("errors").first&.fetch("code").to_s
      code == "plaid_unreachable" ? :unreachable : code.to_sym
    end
end
