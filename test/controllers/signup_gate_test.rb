require "test_helper"

# One sign-up gate in front of the web form, the mobile API and SSO:
# invite codes, the SIGNUP_ALLOWED_EMAILS allowlist and "closed".
class SignupGateTest < ActionDispatch::IntegrationTest
  setup do
    @device_info = { device_id: "gate-device", device_name: "Gate", device_type: "ios", os_version: "17.0", app_version: "1.0.0" }
  end

  test "invite-only: web sign-up without a code is refused" do
    with_self_hosting do
      Setting.onboarding_state = "invite_only"

      assert_no_difference "User.count" do
        post registration_url, params: { user: { email: "stranger@example.com", password: "Password1!" } }
      end
      assert_redirected_to new_registration_path
    end
  end

  test "invite-only: a valid code works once" do
    with_self_hosting do
      Setting.onboarding_state = "invite_only"
      code = InviteCode.generate!

      assert_difference "User.count", 1 do
        post registration_url, params: { user: { email: "finn@example.com", password: "Password1!", invite_code: code } }
      end
      assert_redirected_to root_url

      delete session_path(Session.order(:created_at).last) rescue nil
      assert_no_difference "User.count" do
        post registration_url, params: { user: { email: "fenner@example.com", password: "Password1!", invite_code: code } }
      end
    end
  end

  test "allowlisted email signs up without a code; others still need one" do
    with_self_hosting do
      with_env_overrides SIGNUP_ALLOWED_EMAILS: "Finn@Example.com, fenner@example.com" do
        Setting.onboarding_state = "open"

        assert_no_difference "User.count" do
          post registration_url, params: { user: { email: "stranger@example.com", password: "Password1!" } }
        end

        assert_difference "User.count", 1 do
          post registration_url, params: { user: { email: "finn@example.com", password: "Password1!" } }
        end
      end
    end
  end

  test "closed: allowlisted email still gets in, nobody else does" do
    with_self_hosting do
      with_env_overrides SIGNUP_ALLOWED_EMAILS: "finn@example.com" do
        Setting.onboarding_state = "closed"
        code = InviteCode.generate!

        assert_no_difference "User.count" do
          post registration_url, params: { user: { email: "stranger@example.com", password: "Password1!", invite_code: code } }
        end
        assert_redirected_to new_session_path

        assert_difference "User.count", 1 do
          post registration_url, params: { user: { email: "finn@example.com", password: "Password1!" } }
        end
      end
    end
  end

  test "closed: the mobile API refuses sign-ups too" do
    with_self_hosting do
      Setting.onboarding_state = "closed"

      assert_no_difference "User.count" do
        post "/api/v1/auth/signup", params: {
          user: { email: "api-stranger@example.com", password: "SecurePass123!", first_name: "A", last_name: "B" },
          device: @device_info
        }
      end
      assert_response :forbidden
    end
  end

  test "allowlist: the mobile API needs a code for unlisted emails" do
    with_self_hosting do
      with_env_overrides SIGNUP_ALLOWED_EMAILS: "finn@example.com" do
        Setting.onboarding_state = "open"

        assert_no_difference "User.count" do
          post "/api/v1/auth/signup", params: {
            user: { email: "api-stranger@example.com", password: "SecurePass123!", first_name: "A", last_name: "B" },
            device: @device_info
          }
        end
        assert_response :forbidden
      end
    end
  end
end
