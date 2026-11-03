# Onboarding is one screen: connect a bank through Plaid (or drop Apple Card statements), then the
# dashboard. Name, preferences, categories and budgets are set later in Settings and Budgets.
class OnboardingsController < ApplicationController
  layout "wizard"

  before_action :set_user
  before_action :load_invitation
  before_action :skip_when_nothing_to_connect, only: :show

  def show
    @can_link_plaid = !Current.family.needs_plaid_setup?
    @plaid_keys_editable = Current.user.admin?
    @credential = Current.family.plaid_credential || Current.family.build_plaid_credential
  end

  # Keys pasted on the onboarding screen: checked with Plaid right away, answered in plain words. When they
  # work, the page opens Plaid Link straight away.
  def plaid_keys
    return head(:forbidden) unless Current.user.admin?

    result = PlaidKeySetup.new(Current.family, params[:keys]).call
    if result.saved?
      render json: {
        ok: true,
        message: t(".saved_#{result.environment}"),
        link_url: new_plaid_item_path(region: "us", accountable_type: "Depository")
      }
    else
      render json: { ok: false, message: t(".#{result.status}") }, status: :unprocessable_entity
    end
  end

  def finish
    @user.update!(onboarded_at: Time.current) if @user.needs_onboarding?
    redirect_to root_path
  end

  def preferences
  end

  def trial
  end

  private
    def set_user
      @user = Current.user
    end

    def load_invitation
      @invitation = Current.family.invitations.accepted.find_by(email: Current.user.email)
    end

    # Someone joining a household that already has accounts goes straight to its dashboard.
    def skip_when_nothing_to_connect
      return unless @invitation || Current.family.accounts.any?

      @user.update!(onboarded_at: Time.current) if @user.needs_onboarding?
      redirect_to root_path
    end
end
