# A family's own Plaid keys. Always scoped to Current.family (there is no id in
# the route), so nobody can reach another family's keys through it.
class Settings::PlaidCredentialsController < ApplicationController
  layout "settings"

  before_action :ensure_admin
  before_action :set_credential

  helper_method :plaid_redirect_uri

  def show
    set_breadcrumbs
  end

  def update
    result = ArtifinanceCore.call(
      "plaid_credential_update",
      {
        family_id: Current.family.id,
        attributes: credential_params.to_h,
        confirm_relink: params[:confirm_relink] == "1"
      },
      timeout: 30
    )

    unless result.fetch("saved")
      apply_remote_errors(result.fetch("errors"))
      return redirect_to onboarding_path, alert: @credential.errors.full_messages.to_sentence if from_onboarding?

      @relink_required = result["relink_required"]
      return render_invalid
    end

    stranded_count = result.fetch("stranded_count")
    notice = stranded_count.positive? ? t(".saved_relink", count: stranded_count) : t(".saved")
    redirect_to from_onboarding? ? onboarding_path : settings_plaid_credential_path, notice: notice
  end

  def destroy
    ArtifinanceCore.call("plaid_credential_destroy", { family_id: Current.family.id }, timeout: 15)
    redirect_to settings_plaid_credential_path, notice: t(".removed")
  end

  private
    # The onboarding screen saves keys here too, and gets the user back to it.
    def from_onboarding?
      params[:return_to] == "onboarding" && Current.user.needs_onboarding?
    end

    # The Link redirect_url PlaidItemsController sends; users must allow it in
    # their own Plaid dashboard or OAuth banks fail.
    def plaid_redirect_uri
      accounts_url
    end

    def set_credential
      @credential = Current.family.plaid_credential || Current.family.build_plaid_credential
      metadata = ArtifinanceCore.call("plaid_credential_metadata", { family_id: Current.family.id }, timeout: 5)
      @plaid_storage_available = metadata.fetch("storage_available")
      @plaid_environments = metadata.fetch("environments")
      @client_id_last4 = metadata.fetch("client_id_last4")
      @secret_last4 = metadata.fetch("secret_last4")
      @plaid_credential_source = metadata["credential_source"]
      @items_on_family_keys = metadata.fetch("items_on_family_keys")
      @items_on_instance_keys = metadata.fetch("items_on_instance_keys")
    end

    def set_breadcrumbs
      @breadcrumbs = [
        [ t("breadcrumbs.home"), root_path ],
        [ t("settings.plaid_credentials.show.page_title"), nil ]
      ]
    end

    def render_invalid
      set_breadcrumbs
      render :show, status: :unprocessable_entity
    end

    def apply_remote_errors(errors)
      errors.each do |error|
        options = error.fetch("options", {}).symbolize_keys
        @credential.errors.add(error.fetch("attribute"), error.fetch("code").to_sym, **options)
      end
    end

    def credential_params
      params.require(:family_plaid_credential).permit(:client_id, :secret, :environment)
    end

    def ensure_admin
      return if Current.user.admin?

      redirect_to settings_profile_path, alert: t("settings.plaid_credentials.not_authorized")
    end
end
