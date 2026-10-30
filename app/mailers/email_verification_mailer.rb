class EmailVerificationMailer < ApplicationMailer
  def verification_email
    @user = params[:user]
    @subject = t(".subject", product_name: product_name)
    @cta = t(".cta")
    @verification_url = verify_email_verification_url(token: @user.generate_token_for(:email_verification))

    mail to: @user.email, subject: @subject
  end
end
