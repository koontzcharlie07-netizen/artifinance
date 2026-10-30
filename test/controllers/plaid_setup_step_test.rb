require "test_helper"

class PlaidSetupStepTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    sign_in @admin
  end

  test "a family without keys sees the Plaid setup step instead of Link with Plaid" do
    Provider::Registry.stubs(:plaid_provider_for_region).returns(mock("instance_plaid"))
    refute @admin.family.plaid_instance_keys_allowed?

    get new_depository_url(step: "method_select")

    assert_response :success
    assert_select "[data-testid=plaid-setup-step][href=?]", settings_plaid_credential_path(anchor: "plaid-setup-guide")
    assert_no_match(/Link with Plaid/, response.body)
  end

  test "a family with its own keys gets Link with Plaid" do
    @admin.family.create_plaid_credential!(client_id: "c", secret: "s")

    get new_depository_url(step: "method_select")

    assert_select "[data-testid=plaid-setup-step]", count: 0
    assert_match(/Link with Plaid/, response.body)
  end
end
