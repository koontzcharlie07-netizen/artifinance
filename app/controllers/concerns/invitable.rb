module Invitable
  extend ActiveSupport::Concern

  included do
    helper_method :invite_code_required?, :signup_allowlist_enabled?
  end

  private
    def invite_code_required?
      return false if @invitation.present?
      return true if SignupAllowlist.enabled?
      if self_hosted?
        Setting.onboarding_state == "invite_only" && Setting.invite_only_default_family_id.blank?
      else
        ENV["REQUIRE_INVITE_CODE"] == "true"
      end
    end

    def signup_allowlist_enabled?
      SignupAllowlist.enabled?
    end

    # The one sign-up check shared by every way to create an account (web form,
    # mobile API, SSO). Returns nil when this email may sign up, :closed, or
    # :invite_code_required (the caller must then claim a valid invite code).
    def signup_gate(email, invitation: @invitation)
      return nil if invitation.present?
      return nil if SignupAllowlist.include?(email)
      return :closed if self_hosted? && Setting.onboarding_state == "closed"
      return :invite_code_required if invite_code_required?

      nil
    end

    def self_hosted?
      Rails.application.config.app_mode.self_hosted?
    end
end
