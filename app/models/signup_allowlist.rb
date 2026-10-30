# Emails allowed to create an account without an invite code, from the
# SIGNUP_ALLOWED_EMAILS env var (comma or space separated, case-insensitive).
# When the list is set, everyone else needs an invite code or an invitation.
module SignupAllowlist
  module_function

  def emails
    ENV["SIGNUP_ALLOWED_EMAILS"].to_s.split(/[\s,;]+/).map { |email| email.strip.downcase }.reject(&:blank?)
  end

  def enabled?
    emails.any?
  end

  def include?(email)
    email.present? && emails.include?(email.to_s.strip.downcase)
  end
end
