require "test_helper"

class EmailVerificationsControllerTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  test "self-serve sign-up must verify its email before using the app" do
    with_env_overrides("SIGNUP_EMAIL_VERIFICATION" => "true") do
      assert_enqueued_emails 1 do
        post registration_url, params: { user: { email: "new-person@example.com", password: "Password1!" } }
      end
      assert_redirected_to email_verification_path

      user = User.find_by!(email: "new-person@example.com")
      assert user.email_verification_pending?
      assert user.admin?, "a self-serve sign-up runs its own household"
      assert_not_equal families(:dylan_family), user.family

      # Every app page sends them back to "check your email".
      get root_url
      assert_redirected_to email_verification_path
      get accounts_url
      assert_redirected_to email_verification_path

      get email_verification_url
      assert_response :success
      assert_select "[data-testid=email-verification-pending]"
      assert_includes response.body, "new-person@example.com"

      # The link from the email unlocks the account.
      get verify_email_verification_url(token: user.generate_token_for(:email_verification))
      assert_redirected_to root_url
      user.reload
      refute user.email_verification_pending?
      assert user.email_verified_at.present?

      # The same link can't be used twice.
      get verify_email_verification_url(token: user.generate_token_for(:email_verification).reverse)
      assert_redirected_to new_session_path
    end
  end

  test "the verification email links to the verify URL" do
    user = users(:family_admin)
    user.update!(email_verification_pending: true)

    email = EmailVerificationMailer.with(user: user).verification_email
    assert_equal [ user.email ], email.to
    assert_match %r{/email_verification/verify\?token=}, email.body.encoded
  end

  test "a used or bogus token does nothing" do
    user = users(:family_admin)
    user.update!(email_verification_pending: true)
    token = user.generate_token_for(:email_verification)
    user.verify_email!

    get verify_email_verification_url(token: token)
    assert_redirected_to new_session_path
    assert_equal I18n.t("email_verifications.verify.invalid_token"), flash[:alert]

    get verify_email_verification_url(token: "bogus")
    assert_redirected_to new_session_path
  end

  test "an unverified user can't sign in through the API" do
    user = users(:family_admin)
    user.update!(email_verification_pending: true)

    post "/api/v1/auth/login", params: { email: user.email, password: user_password_test,
                                         device: { device_id: "d1", device_name: "t", device_type: "ios", os_version: "1", app_version: "1" } }, as: :json
    assert_response :forbidden
  end

  test "mobile API sign-up is refused while verification is required" do
    with_env_overrides("SIGNUP_EMAIL_VERIFICATION" => "true") do
      assert_no_difference "User.count" do
        post "/api/v1/auth/signup", params: { user: { email: "api-new@example.com", password: "Password1!" },
                                              device: { device_id: "d1", device_name: "t", device_type: "ios", os_version: "1", app_version: "1" } }, as: :json
      end
      assert_response :forbidden
    end
  end

  test "resend sends another verification email" do
    user = users(:family_admin)
    user.update!(email_verification_pending: true)
    sign_in user

    assert_enqueued_emails 1 do
      post email_verification_url
    end
    assert_redirected_to email_verification_path
  end

  test "invited people don't need to verify (the invitation was emailed to them)" do
    invitation = invitations(:one)
    with_env_overrides("SIGNUP_EMAIL_VERIFICATION" => "true") do
      post registration_url, params: { user: { email: invitation.email, password: "Password1!", invitation: invitation.token } }
    end

    user = User.find_by!(email: invitation.email)
    refute user.email_verification_pending?
    assert_redirected_to root_url
  end

  test "resetting the password through the emailed link also verifies the email" do
    user = users(:family_admin)
    user.update!(email_verification_pending: true)
    AuthConfig.stubs(:password_reset_enabled?).returns(true)

    patch password_reset_url(token: user.generate_token_for(:password_reset)), params: {
      user: { password: "NewPassword1!", password_confirmation: "NewPassword1!" }
    }

    assert_redirected_to new_session_path
    refute user.reload.email_verification_pending?
  end
end
