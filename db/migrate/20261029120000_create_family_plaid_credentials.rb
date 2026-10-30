class CreateFamilyPlaidCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :family_plaid_credentials, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      # Both columns hold Active Record encryption ciphertext, so text, not string.
      t.text :client_id, null: false
      t.text :secret, null: false
      t.string :environment, null: false, default: "sandbox"
      t.timestamps
    end

    add_check_constraint :family_plaid_credentials,
      "environment IN ('sandbox', 'production')",
      name: "chk_family_plaid_credentials_environment"

    # Which keys an item was linked with: an access token only works with the
    # client id that created it, so syncs must keep using that same source.
    add_column :plaid_items, :credential_source, :string, null: false, default: "instance"
    add_check_constraint :plaid_items,
      "credential_source IN ('instance', 'family')",
      name: "chk_plaid_items_credential_source"
  end
end
