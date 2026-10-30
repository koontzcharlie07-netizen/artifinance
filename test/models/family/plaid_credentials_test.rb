require "test_helper"
require "ostruct"

# Per-family Plaid keys: which keys a family's links and syncs use.
class Family::PlaidCredentialsTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @other_family = families(:empty)
    @instance_provider = mock("instance_plaid")
    Provider::Registry.stubs(:plaid_provider_for_region).returns(@instance_provider)
  end

  test "a family with no keys can't link banks on the instance keys" do
    refute @family.plaid_instance_keys_allowed?
    assert_nil @family.plaid_credential_source
    assert @family.needs_plaid_setup?
    assert_nil @family.plaid_provider_for(:us)
    assert_nil @family.plaid_provider_for(:us, credential_source: "instance")
    refute @family.can_connect_plaid_us?
    assert_nil @family.get_link_token(webhooks_url: "https://x/webhooks", redirect_url: "https://x/accounts")
  end

  test "creating a Plaid item without keys is refused" do
    Provider::Plaid.any_instance.expects(:exchange_public_token).never
    @instance_provider.expects(:exchange_public_token).never

    assert_raises(PlaidItem::Provided::MissingCredentialsError) do
      @family.create_plaid_item!(public_token: "public-token", item_name: "Bank", region: "us")
    end
  end

  test "the owner's family can be allowed the instance keys explicitly" do
    @family.update!(plaid_instance_keys_allowed: true)

    assert_equal "instance", @family.plaid_credential_source
    refute @family.needs_plaid_setup?
    assert_same @instance_provider, @family.plaid_provider_for(:us)
    assert @family.can_connect_plaid_us?
  end

  test "uses the family's own keys when it has them" do
    @family.create_plaid_credential!(client_id: "dylan-client", secret: "dylan-secret")

    provider = @family.plaid_provider_for(:us)

    assert_equal "family", @family.plaid_credential_source
    refute_same @instance_provider, provider
    assert_equal "dylan-client", provider.client.api_client.config.api_key["PLAID-CLIENT-ID"]
    assert_equal "dylan-secret", provider.client.api_client.config.api_key["PLAID-SECRET"]
  end

  test "each family only ever gets its own keys" do
    @family.create_plaid_credential!(client_id: "dylan-client", secret: "dylan-secret")
    @other_family.create_plaid_credential!(client_id: "other-client", secret: "other-secret")

    dylan_key = @family.reload.plaid_provider_for(:us).client.api_client.config.api_key
    other_key = @other_family.reload.plaid_provider_for(:us).client.api_client.config.api_key

    assert_equal "dylan-secret", dylan_key["PLAID-SECRET"]
    assert_equal "other-secret", other_key["PLAID-SECRET"]

    # An item synced for the Dylan family uses the Dylan keys, never the other family's.
    plaid_items(:one).update!(credential_source: "family")
    item_key = PlaidItem.find(plaid_items(:one).id).plaid_provider.client.api_client.config.api_key
    assert_equal "dylan-client", item_key["PLAID-CLIENT-ID"]
  end

  test "a family without keys never borrows another family's keys" do
    @other_family.create_plaid_credential!(client_id: "other-client", secret: "other-secret")
    Provider::Registry.stubs(:plaid_provider_for_region).returns(nil)

    assert_nil @family.plaid_provider_for(:us)
    refute @family.can_connect_plaid_us?
    assert_nil @family.plaid_provider_for(:us, credential_source: "family")
  end

  test "new items record the keys they were linked with" do
    @family.create_plaid_credential!(client_id: "dylan-client", secret: "dylan-secret")
    Provider::Plaid.any_instance.expects(:exchange_public_token).with("public-token")
      .returns(OpenStruct.new(item_id: "item_family_keys", access_token: "access-family"))
    PlaidItem.any_instance.stubs(:sync_later)

    item = @family.create_plaid_item!(public_token: "public-token", item_name: "Bank", region: "us")

    assert_equal "family", item.credential_source
    assert_equal @family.plaid_credential.fingerprint, item.credential_fingerprint
  end

  test "items linked with the instance keys keep using them after the family adds its own" do
    @family.update!(plaid_instance_keys_allowed: true)
    item = plaid_items(:one)
    assert_equal "instance", item.credential_source

    @family.create_plaid_credential!(client_id: "dylan-client", secret: "dylan-secret")

    assert_same @instance_provider, PlaidItem.find(item.id).plaid_provider
  end

  test "items linked with family keys fail clearly when those keys are removed" do
    item = plaid_items(:one)
    item.update!(credential_source: "family")

    assert_raises(PlaidItem::Provided::MissingCredentialsError) { PlaidItem.find(item.id).plaid_provider }
  end

  test "destroying the family destroys its keys" do
    family = Family.create!(name: "Short-lived")
    credential = family.create_plaid_credential!(client_id: "a", secret: "b")

    family.destroy

    refute FamilyPlaidCredential.exists?(credential.id)
  end
end
