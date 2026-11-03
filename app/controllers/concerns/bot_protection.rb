module BotProtection
  extend ActiveSupport::Concern

  HONEYPOT_FIELD = "contact_website".freeze
  MIN_FORM_SECONDS = 2
  TURNSTILE_VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify".freeze

  included do
    helper_method :bot_protection_markup
  end

  private
    def bot_protection_markup
      ArtifinanceCore.call("access_bot_form", {}, timeout: 5).fetch("html")
    end

    def human_form_submission?(min_seconds: MIN_FORM_SECONDS)
      ArtifinanceCore.call(
        "access_human_submission",
        {
          kind: controller_name.singularize,
          honeypot: params[HONEYPOT_FIELD],
          form_token: params[:form_token],
          turnstile_token: params["cf-turnstile-response"],
          remote_ip: request.remote_ip,
          min_seconds: min_seconds
        },
        timeout: 10
      ).fetch("human")
    end
end
