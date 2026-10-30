require "test_helper"

# Instance-wide settings are shared by every family on a hosted server, so a
# family admin (not the instance owner) may neither read nor change them.
class InstanceSettingsAccessTest < ActionDispatch::IntegrationTest
  test "family admin can't open or change self-hosting settings" do
    with_self_hosting do
      Setting.onboarding_state = "invite_only"
      sign_in users(:family_admin)

      get settings_hosting_url
      assert_redirected_to settings_profile_path

      patch settings_hosting_url, params: { setting: { onboarding_state: "open" } }
      assert_redirected_to settings_profile_path
      assert_equal "invite_only", Setting.onboarding_state
    end
  end

  test "family admin can't change instance-wide Plaid keys" do
    sign_in users(:family_admin)
    Setting["plaid_client_id"] = "instance-client"

    patch settings_providers_url, params: { setting: { plaid_client_id: "hijacked" } }

    assert_redirected_to settings_providers_path
    assert_equal "instance-client", Setting["plaid_client_id"]
  end

  test "instance owner can still change instance-wide Plaid keys" do
    sign_in users(:sure_support_staff)

    patch settings_providers_url, params: { setting: { plaid_client_id: "owner-client" } }

    assert_equal "owner-client", Setting["plaid_client_id"]
  end
end
