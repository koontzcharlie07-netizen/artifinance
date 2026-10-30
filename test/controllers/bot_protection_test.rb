require "test_helper"

class BotProtectionTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper
  test "sign-up form carries the bot checks" do
    get new_registration_url

    assert_select "input[name=#{BotProtection::HONEYPOT_FIELD}]"
    assert_select "input[type=hidden][name=form_token]"
  end

  test "a filled honeypot is refused" do
    with_bot_protection do
      assert_no_difference "User.count" do
        post registration_url, params: signup_params("bot@example.com").merge(BotProtection::HONEYPOT_FIELD => "http://spam", form_token: token(10.seconds.ago))
      end
      assert_response :unprocessable_entity
    end
  end

  test "a submit without a rendered form, or faster than a person types, is refused" do
    with_bot_protection do
      assert_no_difference "User.count" do
        post registration_url, params: signup_params("no-token@example.com")
        post registration_url, params: signup_params("too-fast@example.com").merge(form_token: token(Time.current))
        post registration_url, params: signup_params("forged@example.com").merge(form_token: "forged")
      end
    end
  end

  test "a person filling the form signs up" do
    with_bot_protection do
      assert_difference "User.count", 1 do
        post registration_url, params: signup_params("person@example.com").merge(form_token: token(5.seconds.ago))
      end
    end
  end

  test "sign-in refuses a filled honeypot but allows a quick, legitimate submit" do
    with_bot_protection do
      post sessions_url, params: { email: users(:family_admin).email, password: user_password_test,
                                   BotProtection::HONEYPOT_FIELD => "x", form_token: token(Time.current) }
      assert_redirected_to new_session_path
      assert_equal I18n.t("sessions.create.bot_check_failed"), flash[:alert]

      post sessions_url, params: { email: users(:family_admin).email, password: user_password_test, form_token: token(Time.current) }
      assert_redirected_to root_path
    end
  end

  test "with Turnstile keys set, the forms render the widget" do
    with_turnstile do
      get new_registration_url
      assert_select "[data-testid=turnstile][data-sitekey=?]", "site-key-test"
      get new_session_url
      assert_select "[data-testid=turnstile]"
      get new_password_reset_url
      assert_select "[data-testid=turnstile]"
    end
  end

  test "with Turnstile on, a missing or rejected token is refused and a verified one passes" do
    with_turnstile do
      Faraday.expects(:post).never
      assert_no_difference "User.count" do
        post registration_url, params: signup_params("no-turnstile@example.com").merge(form_token: token(5.seconds.ago))
      end
      assert_response :unprocessable_entity
      Faraday.unstub(:post)

      Faraday.expects(:post).with(BotProtection::TURNSTILE_VERIFY_URL, has_entries(secret: "secret-key-test", response: "bad-token"))
        .returns(stub(body: { success: false, "error-codes" => [ "invalid-input-response" ] }.to_json))
      assert_no_difference "User.count" do
        post registration_url, params: signup_params("bad-turnstile@example.com").merge(form_token: token(5.seconds.ago), "cf-turnstile-response" => "bad-token")
      end
      assert_response :unprocessable_entity

      Faraday.expects(:post).with(BotProtection::TURNSTILE_VERIFY_URL, has_entries(response: "good-token"))
        .returns(stub(body: { success: true }.to_json))
      assert_difference "User.count", 1 do
        post registration_url, params: signup_params("good-turnstile@example.com").merge(form_token: token(5.seconds.ago), "cf-turnstile-response" => "good-token")
      end
    end
  end

  test "with Turnstile on, sign-in needs a verified token" do
    with_turnstile do
      post sessions_url, params: { email: users(:family_admin).email, password: user_password_test, form_token: token(Time.current) }
      assert_redirected_to new_session_path
      assert_equal I18n.t("sessions.create.bot_check_failed"), flash[:alert]

      Faraday.stubs(:post).returns(stub(body: { success: true }.to_json))
      post sessions_url, params: { email: users(:family_admin).email, password: user_password_test, form_token: token(Time.current), "cf-turnstile-response" => "good-token" }
      assert_redirected_to root_path
    end
  end

  test "password reset requests get the bot check" do
    AuthConfig.stubs(:password_reset_enabled?).returns(true)
    with_bot_protection do
      assert_no_enqueued_emails do
        post password_reset_url, params: { email: users(:family_admin).email }
      end
      assert_redirected_to new_password_reset_path
      assert_equal I18n.t("password_resets.create.bot_check_failed"), flash[:alert]

      assert_enqueued_emails 1 do
        post password_reset_url, params: { email: users(:family_admin).email, form_token: token(Time.current) }
      end
      assert_redirected_to new_password_reset_path(step: "pending")
    end
  end

  test "Turnstile service errors fail closed" do
    with_turnstile do
      Faraday.stubs(:post).raises(Faraday::ConnectionFailed.new("down"))
      assert_no_difference "User.count" do
        post registration_url, params: signup_params("cf-down@example.com").merge(form_token: token(5.seconds.ago), "cf-turnstile-response" => "t")
      end
    end
  end

  private
    def with_bot_protection(&block)
      with_env_overrides("BOT_PROTECTION" => "true", &block)
    end

    def with_turnstile(&block)
      with_env_overrides("BOT_PROTECTION" => "true", "TURNSTILE_SITE_KEY" => "site-key-test", "TURNSTILE_SECRET_KEY" => "secret-key-test", &block)
    end

    def signup_params(email)
      { user: { email: email, password: "Password1!" } }
    end

    def token(at)
      travel_to(at) { Rails.application.message_verifier(:bot_protection).generate(Time.current.to_f, expires_in: 1.day, purpose: :bot_protection) }
    end
end
