# The "check your inbox" step after self-serve sign-up, and the link in the
# verification email. Until the link is clicked, Authentication#require_verified_email!
# sends every page here.
class EmailVerificationsController < ApplicationController
  skip_email_verification
  skip_authentication only: :verify

  layout "auth"

  def show
    return redirect_to(root_path) unless Current.user.email_verification_pending?

    @email = Current.user.email
  end

  def create
    Current.user.send_email_verification(remote_ip: request.remote_ip) if Current.user.email_verification_pending?
    redirect_to email_verification_path, notice: t(".sent")
  end

  def verify
    result = ArtifinanceCore.call(
      "access_verify_email",
      { token: params[:token], remote_ip: request.remote_ip },
      timeout: 10
    )
    user = User.find_by(id: result["user_id"])

    if user
      if Current.session&.user == user || find_session_by_cookie&.user == user
        redirect_to root_path, notice: t(".verified")
      else
        redirect_to new_session_path, notice: t(".verified_sign_in")
      end
    else
      redirect_to new_session_path, alert: t(".invalid_token")
    end
  end
end
