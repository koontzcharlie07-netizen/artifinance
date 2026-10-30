require "test_helper"

class FamilyPlaidCredentialTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "client id and secret are encrypted at rest" do
    credential = @family.create_plaid_credential!(client_id: "client-abc-1234", secret: "secret-xyz-9876", environment: "sandbox")

    raw = FamilyPlaidCredential.connection.select_one(
      FamilyPlaidCredential.sanitize_sql([ "SELECT client_id, secret FROM family_plaid_credentials WHERE id = ?", credential.id ])
    )

    refute_includes raw["client_id"], "client-abc-1234"
    refute_includes raw["secret"], "secret-xyz-9876"
    assert_includes FamilyPlaidCredential.encrypted_attributes, :client_id
    assert_includes FamilyPlaidCredential.encrypted_attributes, :secret
    assert_equal "secret-xyz-9876", credential.reload.secret
  end

  test "only the last four characters are exposed for display" do
    credential = FamilyPlaidCredential.new(family: @family, client_id: "client-abc-1234", secret: "secret-xyz-9876")

    assert_equal "1234", credential.client_id_last4
    assert_equal "9876", credential.secret_last4
    refute_includes credential.inspect, "secret-xyz-9876"
    refute_includes credential.inspect, "client-abc-1234"
    refute_includes credential.to_json, "secret-xyz-9876"
    refute_includes credential.to_json, "client-abc-1234"
  end

  test "requires both keys and a known environment" do
    credential = FamilyPlaidCredential.new(family: @family, environment: "development")

    refute credential.valid?
    assert credential.errors.of_kind?(:client_id, :blank)
    assert credential.errors.of_kind?(:secret, :blank)
    assert credential.errors.of_kind?(:environment, :inclusion)
  end

  test "one set of keys per family" do
    @family.create_plaid_credential!(client_id: "a", secret: "b")
    duplicate = FamilyPlaidCredential.new(family: @family, client_id: "c", secret: "d")

    refute duplicate.valid?
  end

  test "refuses to store keys in production unless encryption keys come from env" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))
    ActiveRecordEncryptionConfig.stubs(:complete_env?).returns(false)

    credential = FamilyPlaidCredential.new(family: @family, client_id: "a", secret: "b")
    refute credential.valid?
    assert credential.errors.of_kind?(:base, :encryption_not_configured)

    ActiveRecordEncryptionConfig.stubs(:complete_env?).returns(true)
    assert credential.valid?
  end

  test "builds a Plaid client with the family's own keys and environment" do
    credential = FamilyPlaidCredential.new(family: @family, client_id: "fam-client", secret: "fam-secret", environment: "production")

    config = credential.provider(:us).client.api_client.config
    assert_equal "fam-client", config.api_key["PLAID-CLIENT-ID"]
    assert_equal "fam-secret", config.api_key["PLAID-SECRET"]
    assert_equal Plaid::Configuration::Environment["production"], config.server_index
  end
end
