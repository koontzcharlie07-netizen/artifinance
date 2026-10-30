require "test_helper"

class WebhooksControllerTest < ActionDispatch::IntegrationTest
  test "plaid webhook is verified with the keys that linked the item" do
    item = plaid_items(:one)
    item.update!(credential_source: "family")
    item.family.create_plaid_credential!(client_id: "fam-client", secret: "fam-secret")
    body = { webhook_type: "TRANSACTIONS", webhook_code: "SYNC_UPDATES_AVAILABLE", item_id: item.plaid_id }.to_json

    Provider::Registry.expects(:plaid_provider_for_region).never
    Provider::Plaid.any_instance.expects(:validate_webhook!).with("jwt", body).once
    PlaidItem::WebhookProcessor.any_instance.expects(:process).once

    post webhooks_plaid_path, params: body, headers: { "Plaid-Verification" => "jwt", "CONTENT_TYPE" => "application/json" }

    assert_response :ok
  end

  test "plaid webhook for an item on instance keys uses the instance keys" do
    item = plaid_items(:one)
    item.family.update!(plaid_instance_keys_allowed: true)
    body = { webhook_type: "TRANSACTIONS", webhook_code: "SYNC_UPDATES_AVAILABLE", item_id: item.plaid_id }.to_json
    instance_provider = mock("instance_plaid")
    instance_provider.expects(:validate_webhook!).with("jwt", body)
    Provider::Registry.stubs(:plaid_provider_for_region).with(:us).returns(instance_provider)
    PlaidItem::WebhookProcessor.any_instance.stubs(:process)

    post webhooks_plaid_path, params: body, headers: { "Plaid-Verification" => "jwt", "CONTENT_TYPE" => "application/json" }

    assert_response :ok
  end

  test "plaid webhook is rejected when verification fails" do
    plaid_items(:one).family.update!(plaid_instance_keys_allowed: true)
    body = { webhook_type: "TRANSACTIONS", item_id: plaid_items(:one).plaid_id }.to_json
    instance_provider = mock("instance_plaid")
    instance_provider.expects(:validate_webhook!).raises(JWT::VerificationError)
    Provider::Registry.stubs(:plaid_provider_for_region).with(:us).returns(instance_provider)
    PlaidItem::WebhookProcessor.any_instance.expects(:process).never

    post webhooks_plaid_path, params: body, headers: { "Plaid-Verification" => "bad", "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
  end
end
