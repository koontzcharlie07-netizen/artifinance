# Whatever someone pasted from Plaid's Keys page: one key or both, in any order, with labels, quotes or spaces.
# Plaid client IDs are 24 hex characters and secrets 30; that's how the two are told apart. Sandbox and
# Production secrets look alike, so the environment is found by trying the keys with Plaid (PlaidKeySetup).
class PlaidKeyPaste
  CLIENT_ID_LENGTH = 24
  SECRET_LENGTH = 30

  attr_reader :client_ids, :secrets, :odd_tokens

  def initialize(text)
    tokens = text.to_s.scan(/[0-9a-zA-Z]{16,}/).map(&:downcase).uniq
    hex = tokens.select { |t| t.match?(/\A[0-9a-f]+\z/) }
    @client_ids = hex.select { |t| t.length == CLIENT_ID_LENGTH }
    @secrets = hex.select { |t| t.length == SECRET_LENGTH }
    @odd_tokens = hex - @client_ids - @secrets
  end

  def complete?
    client_ids.one? && secrets.any?
  end

  # A plain-words note on what's still missing, or nil when there's something to try.
  def problem
    if client_ids.many? then :two_client_ids
    elsif client_ids.empty? && secrets.empty? then odd_tokens.any? ? :cut_off : :nothing_found
    elsif client_ids.empty? then :needs_client_id
    elsif secrets.empty? then odd_tokens.any? ? :cut_off : :needs_secret
    end
  end
end
