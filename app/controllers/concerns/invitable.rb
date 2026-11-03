module Invitable
  extend ActiveSupport::Concern

  included do
    helper_method :invite_code_required?, :signup_allowlist_enabled?
  end

  private
    def invite_code_required?
      ArtifinanceCore.call("access_invite_required", access_facts, timeout: 5).fetch("required")
    end

    def signup_allowlist_enabled?
      SignupAllowlist.enabled?
    end

    # The one sign-up check shared by every way to create an account (web form,
    # mobile API, SSO). Returns nil when this email may sign up, :closed, or
    # :invite_code_required (the caller must then claim a valid invite code).
    def signup_gate(email, invitation: @invitation)
      gate = ArtifinanceCore.call(
        "access_signup_gate",
        access_facts.merge(email: email, invitation_present: invitation.present?),
        timeout: 5
      ).fetch("gate")
      gate&.to_sym
    end

    def self_hosted?
      Rails.application.config.app_mode.self_hosted?
    end

    def access_facts
      {
        invitation_present: @invitation.present?,
        self_hosted: self_hosted?,
        onboarding_state: Setting.onboarding_state,
        invite_only_default_family_id: Setting.invite_only_default_family_id
      }
    end
end
