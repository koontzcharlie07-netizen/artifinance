# Cheap bot checks for the sign-up and sign-in forms (shared/_bot_protection):
#
# - a honeypot field people never see or fill in;
# - a signed "form rendered at" time, so a POST that arrives faster than a
#   person could type (or without ever loading the form) is refused;
# - Cloudflare Turnstile, when TURNSTILE_SITE_KEY and TURNSTILE_SECRET_KEY are set.
#
# Rate limits for the same endpoints live in config/initializers/rack_attack.rb.
module BotProtection
  extend ActiveSupport::Concern

  HONEYPOT_FIELD = "contact_website".freeze
  MIN_FORM_SECONDS = 2
  MAX_FORM_AGE = 1.day
  TURNSTILE_VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze
  # Decided once at boot, so code that stubs Rails.env doesn't flip it.
  ENABLED_BY_DEFAULT = Rails.env.production?

  included do
    helper_method :bot_protection_form_token, :turnstile_site_key
  end

  class_methods do
    # On by default in production; BOT_PROTECTION=false/true overrides.
    def bot_protection_enabled?
      ENV.fetch("BOT_PROTECTION", ENABLED_BY_DEFAULT.to_s) == "true"
    end

    def turnstile_enabled?
      ENV["TURNSTILE_SITE_KEY"].present? && ENV["TURNSTILE_SECRET_KEY"].present?
    end
  end

  private
    def bot_protection_form_token
      bot_protection_verifier.generate(Time.current.to_f, expires_in: MAX_FORM_AGE, purpose: :bot_protection)
    end

    def turnstile_site_key
      ENV["TURNSTILE_SITE_KEY"] if self.class.turnstile_enabled?
    end

    # True when the request looks like a person submitting the form we rendered.
    # min_seconds guards against scripted instant submits; sign-in passes 0
    # because password managers legitimately submit right away.
    def human_form_submission?(min_seconds: MIN_FORM_SECONDS)
      return true unless self.class.bot_protection_enabled?
      return false if params[HONEYPOT_FIELD].present?

      rendered_at = bot_protection_verifier.verified(params[:form_token].to_s, purpose: :bot_protection)
      return false unless rendered_at
      return false if Time.current.to_f - rendered_at.to_f < min_seconds

      return turnstile_passed? if self.class.turnstile_enabled?

      true
    end

    def turnstile_passed?
      token = params["cf-turnstile-response"].to_s
      return false if token.blank?

      response = Faraday.post(TURNSTILE_VERIFY_URL, {
        secret: ENV["TURNSTILE_SECRET_KEY"],
        response: token,
        remoteip: request.remote_ip
      })
      JSON.parse(response.body)["success"] == true
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.warn("Turnstile check failed: #{e.class}")
      false
    end

    def bot_protection_verifier
      Rails.application.message_verifier(:bot_protection)
    end
end
