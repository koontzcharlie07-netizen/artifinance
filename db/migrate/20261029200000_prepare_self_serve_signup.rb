class PrepareSelfServeSignup < ActiveRecord::Migration[8.1]
  def up
    # Only families flagged here may link banks with the instance-wide Plaid
    # keys. Everyone else must save their own keys first.
    add_column :families, :plaid_instance_keys_allowed, :boolean, null: false, default: false

    # Families already linked on the instance keys keep that permission, so
    # nothing that works today stops working.
    execute <<~SQL.squish
      UPDATE families SET plaid_instance_keys_allowed = TRUE
      WHERE id IN (SELECT DISTINCT family_id FROM plaid_items WHERE credential_source = 'instance')
    SQL

    # Which family keys an item was linked with (a digest of client id +
    # environment), so a key change can flag the items it strands.
    add_column :plaid_items, :credential_fingerprint, :string

    # Self-serve sign-ups must verify their email before using the app.
    # Existing accounts aren't pending, so nobody already signed up is locked out.
    add_column :users, :email_verification_pending, :boolean, null: false, default: false
    add_column :users, :email_verified_at, :datetime
  end

  def down
    remove_column :users, :email_verified_at
    remove_column :users, :email_verification_pending
    remove_column :plaid_items, :credential_fingerprint
    remove_column :families, :plaid_instance_keys_allowed
  end
end
