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
    attributes = credential_params.to_h.symbolize_keys
    # Blank key fields on an existing record mean "keep what's saved": the saved
    # values are never put back into the form.
    attributes.delete(:client_id) if attributes[:client_id].blank? && @credential.persisted?
    attributes.delete(:secret) if attributes[:secret].blank? && @credential.persisted?

    previous_fingerprint = @credential.persisted? ? @credential.fingerprint : nil
    @credential.assign_attributes(attributes)

    return render_invalid unless @credential.valid?

    # Test-call Plaid before saving, so wrong keys fail here and not at Link.
    if @credential.changed? && (problem = @credential.verify_with_plaid)
      @credential.errors.add(:base, :"plaid_#{problem}")
      return render_invalid
    end

    # Banks linked with keys from another Plaid account or environment can't
    # sync with the new ones. Require an explicit OK before stranding them.
    stranded = stranded_items(previous_fingerprint, @credential.fingerprint)
    if stranded.any? && params[:confirm_relink] != "1"
      @relink_required = stranded.size
      @credential.errors.add(:base, :relink_confirmation_required, count: stranded.size)
      return render_invalid
    end

    FamilyPlaidCredential.transaction do
      # Older items have no fingerprint; pin them to the keys they were linked
      # with so they show up as "link again" instead of failing obscurely.
      if previous_fingerprint
        Current.family.plaid_items.where(credential_source: "family", credential_fingerprint: nil)
          .update_all(credential_fingerprint: previous_fingerprint)
      end
      @credential.save!
    end

    notice = stranded.any? ? t(".saved_relink", count: stranded.size) : t(".saved")
    redirect_to settings_plaid_credential_path, notice: notice
  end

  def destroy
    credential = Current.family.plaid_credential
    if credential
      FamilyPlaidCredential.transaction do
        Current.family.plaid_items.where(credential_source: "family", credential_fingerprint: nil)
          .update_all(credential_fingerprint: credential.fingerprint)
        credential.destroy!
      end
    end
    redirect_to settings_plaid_credential_path, notice: t(".removed")
  end

  private
    # The Link redirect_url PlaidItemsController sends; users must allow it in
    # their own Plaid dashboard or OAuth banks fail.
    def plaid_redirect_uri
      accounts_url
    end

    def set_credential
      @credential = Current.family.plaid_credential || Current.family.build_plaid_credential
      @items_on_family_keys = Current.family.plaid_items.active.where(credential_source: "family").count
      @items_on_instance_keys = Current.family.plaid_items.active.where(credential_source: "instance").count
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

    def stranded_items(previous_fingerprint, new_fingerprint)
      Current.family.plaid_items.active.where(credential_source: "family").select do |item|
        linked_with = item.credential_fingerprint || previous_fingerprint
        linked_with.present? && linked_with != new_fingerprint
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
