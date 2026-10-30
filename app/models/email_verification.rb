# Self-serve sign-ups verify their email address before they can use the app.
# On by default in production (it needs SMTP). SIGNUP_EMAIL_VERIFICATION=false
# turns it off; SIGNUP_EMAIL_VERIFICATION=true turns it on elsewhere.
module EmailVerification
  # Decided once at boot, so code that stubs Rails.env doesn't flip it.
  REQUIRED_BY_DEFAULT = Rails.env.production?

  module_function

  def required?
    ENV.fetch("SIGNUP_EMAIL_VERIFICATION", REQUIRED_BY_DEFAULT.to_s) == "true"
  end
end
