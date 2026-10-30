require "test_helper"

# "Delete account" for the last person in a household: the bank connections are
# removed at Plaid, then the household and all of its data is deleted.
class UserPurgeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    @family = Family.create!(name: "Leaving")
    @user = @family.users.create!(email: "leaving@example.com", password: "Password1!", role: :admin)
    @credential = @family.create_plaid_credential!(client_id: "leaving-client", secret: "leaving-secret", environment: "sandbox")
    @item = @family.plaid_items.create!(name: "Bank", plaid_id: "item-leaving", access_token: "access-leaving",
                                        credential_source: "family", credential_fingerprint: @credential.fingerprint)
    @account = @family.accounts.create!(name: "Checking", balance: 100, currency: "USD", accountable: Depository.new)
    @entry = @account.entries.create!(name: "Coffee", date: Date.current, amount: 4, currency: "USD", entryable: Transaction.new)
  end

  test "removes the Plaid items at Plaid, then wipes accounts, tokens and keys" do
    Provider::Plaid.any_instance.expects(:remove_item).with("access-leaving").at_least_once

    @user.purge

    refute Family.exists?(@family.id)
    refute User.exists?(@user.id)
    refute PlaidItem.exists?(@item.id)
    refute FamilyPlaidCredential.exists?(@credential.id)
    refute Account.exists?(@account.id)
    refute Entry.exists?(@entry.id)
  end

  test "a transient Plaid failure leaves the data for the retried job" do
    Provider::Plaid.any_instance.expects(:remove_item).raises(
      Plaid::ApiError.new(code: 500, response_body: { "error_code" => "INTERNAL_SERVER_ERROR" }.to_json)
    )

    assert_raises(Plaid::ApiError) { @user.purge }
    assert Family.exists?(@family.id)
    assert PlaidItem.exists?(@item.id)
  end

  test "an item Plaid no longer knows doesn't block deletion" do
    Provider::Plaid.any_instance.stubs(:remove_item).raises(
      Plaid::ApiError.new(code: 400, response_body: { "error_code" => "ITEM_NOT_FOUND" }.to_json)
    )

    @user.purge

    refute Family.exists?(@family.id)
  end

  test "deleting the account through the settings page purges it" do
    Provider::Plaid.any_instance.stubs(:remove_item)

    perform_enqueued_jobs(only: UserPurgeJob) { assert @user.deactivate }

    refute Family.exists?(@family.id)
    refute FamilyPlaidCredential.exists?(@credential.id)
  end
end
