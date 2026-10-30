require "test_helper"

class Settings::PlaidCredentialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:family_admin)
    @family = @admin.family
    # Saving test-calls Plaid; tests below that care stub a failure.
    FamilyPlaidCredential.any_instance.stubs(:verify_with_plaid).returns(nil)
  end

  test "keys Plaid rejects are not saved and the reason is shown" do
    FamilyPlaidCredential.any_instance.stubs(:verify_with_plaid).returns(:invalid_keys)
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "wrong-client", secret: "wrong-secret", environment: "sandbox" }
    }

    assert_response :unprocessable_entity
    assert_nil @family.reload.plaid_credential
    assert_select "[data-testid=plaid-keys-error]", text: /Plaid didn't accept these keys/
    refute_includes response.body, "wrong-secret"
  end

  test "an unreachable Plaid saves nothing" do
    FamilyPlaidCredential.any_instance.stubs(:verify_with_plaid).returns(:unreachable)
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "c", secret: "s", environment: "sandbox" }
    }

    assert_response :unprocessable_entity
    assert_nil @family.reload.plaid_credential
  end

  test "verify_with_plaid maps Plaid's error codes" do
    credential = @family.build_plaid_credential(client_id: "c", secret: "s", environment: "sandbox")
    FamilyPlaidCredential.any_instance.unstub(:verify_with_plaid)
    client = mock
    Provider::Plaid.any_instance.stubs(:client).returns(client)

    client.stubs(:institutions_get).raises(Plaid::ApiError.new(code: 400, response_body: { "error_code" => "INVALID_API_KEYS" }.to_json))
    assert_equal :invalid_keys, credential.verify_with_plaid

    client.stubs(:institutions_get).raises(Plaid::ApiError.new(code: 400, response_body: { "error_code" => "INVALID_FIELD" }.to_json))
    assert_equal :invalid_keys, credential.verify_with_plaid

    client.stubs(:institutions_get).raises(Plaid::ApiError.new(code: 400, response_body: { "error_code" => "UNAUTHORIZED_ENVIRONMENT" }.to_json))
    assert_equal :unauthorized_environment, credential.verify_with_plaid

    client.stubs(:institutions_get).raises(Faraday::ConnectionFailed.new("down"))
    assert_equal :unreachable, credential.verify_with_plaid

    client.stubs(:institutions_get).returns(true)
    assert_nil credential.verify_with_plaid
  end

  test "switching to another Plaid account needs confirmation when banks are linked" do
    credential = @family.create_plaid_credential!(client_id: "old-client", secret: "old-secret", environment: "sandbox")
    item = plaid_items(:one)
    item.update!(credential_source: "family", credential_fingerprint: credential.fingerprint)
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "new-client", secret: "new-secret", environment: "sandbox" }
    }
    assert_response :unprocessable_entity
    assert_equal "old-client", @family.reload.plaid_credential.client_id
    assert_select "[data-testid=plaid-keys-error]", text: /1 linked bank would stop syncing/

    patch settings_plaid_credential_path, params: {
      confirm_relink: "1",
      family_plaid_credential: { client_id: "new-client", secret: "new-secret", environment: "sandbox" }
    }
    assert_redirected_to settings_plaid_credential_path
    assert_equal "new-client", @family.reload.plaid_credential.client_id
    assert PlaidItem.find(item.id).credentials_stale?
    assert_match(/1 bank linked with your old keys needs to be linked again/, flash[:notice])
  end

  test "switching sandbox to production is a switch too" do
    credential = @family.create_plaid_credential!(client_id: "same-client", secret: "sandbox-secret", environment: "sandbox")
    plaid_items(:one).update!(credential_source: "family", credential_fingerprint: credential.fingerprint)
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "", secret: "production-secret", environment: "production" }
    }

    assert_response :unprocessable_entity
    assert_equal "sandbox", @family.reload.plaid_credential.environment
  end

  test "rotating the secret for the same account needs no confirmation" do
    credential = @family.create_plaid_credential!(client_id: "same-client", secret: "old-secret", environment: "sandbox")
    plaid_items(:one).update!(credential_source: "family", credential_fingerprint: credential.fingerprint)
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "", secret: "new-secret", environment: "sandbox" }
    }

    assert_redirected_to settings_plaid_credential_path
    assert_equal "new-secret", @family.reload.plaid_credential.secret
    refute PlaidItem.find(plaid_items(:one).id).credentials_stale?
  end

  test "the keys page shows the setup guide and the redirect URI to allow" do
    sign_in @admin
    get settings_plaid_credential_path

    assert_response :success
    assert_select "#plaid-setup-guide"
    assert_select "[data-testid=plaid-redirect-uri]", text: accounts_url
    assert_select "[data-testid=plaid-keys-none-saved]"
    assert_includes response.body, "nothing yet (add your keys first)"
    refute_includes response.body, "New bank links use: your keys"
  end

  test "after rejected keys the family still has no usable keys" do
    FamilyPlaidCredential.any_instance.stubs(:verify_with_plaid).returns(:invalid_keys)
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "c", secret: "s", environment: "sandbox" }
    }

    assert_includes response.body, "nothing yet (add your keys first)"
    assert @family.reload.needs_plaid_setup?
  end

  test "admin saves keys and only the last four are shown back" do
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "client-abcdef-1234", secret: "secret-uvwxyz-9876", environment: "production" }
    }
    assert_redirected_to settings_plaid_credential_path

    credential = @family.reload.plaid_credential
    assert_equal "client-abcdef-1234", credential.client_id
    assert_equal "production", credential.environment

    get settings_plaid_credential_path
    assert_response :success
    assert_includes response.body, "9876"
    assert_includes response.body, "1234"
    refute_includes response.body, "secret-uvwxyz-9876"
    refute_includes response.body, "client-abcdef-1234"
  end

  test "blank fields keep the saved keys" do
    @family.create_plaid_credential!(client_id: "client-1111", secret: "secret-2222")
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "", secret: "", environment: "production" }
    }

    credential = @family.reload.plaid_credential
    assert_equal "client-1111", credential.client_id
    assert_equal "secret-2222", credential.secret
    assert_equal "production", credential.environment
  end

  test "new keys need both a client id and a secret" do
    sign_in @admin

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "only-client", secret: "", environment: "sandbox" }
    }

    assert_response :unprocessable_entity
    assert_nil @family.reload.plaid_credential
  end

  test "an admin of another family never sees or changes these keys" do
    @family.create_plaid_credential!(client_id: "dylan-client-1234", secret: "dylan-secret-5678")
    other_admin = users(:empty)
    sign_in other_admin

    get settings_plaid_credential_path
    assert_response :success
    refute_includes response.body, "5678"
    refute_includes response.body, "1234"

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "other-client", secret: "other-secret", environment: "sandbox" }
    }
    delete settings_plaid_credential_path

    assert_equal "dylan-secret-5678", @family.reload.plaid_credential.secret
    assert_nil other_admin.family.reload.plaid_credential
  end

  test "members can't manage keys" do
    sign_in users(:family_member)

    get settings_plaid_credential_path
    assert_redirected_to settings_profile_path

    patch settings_plaid_credential_path, params: {
      family_plaid_credential: { client_id: "x", secret: "y", environment: "sandbox" }
    }
    assert_nil @family.reload.plaid_credential
  end

  test "admin removes keys" do
    @family.create_plaid_credential!(client_id: "a", secret: "b")
    sign_in @admin

    delete settings_plaid_credential_path

    assert_redirected_to settings_plaid_credential_path
    assert_nil @family.reload.plaid_credential
  end
end
