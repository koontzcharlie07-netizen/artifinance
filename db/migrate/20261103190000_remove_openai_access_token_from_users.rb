class RemoveOpenaiAccessTokenFromUsers < ActiveRecord::Migration[8.1]
  # AI chat is gone, and with it the per-user OpenAI key a preview build briefly stored. A no-op where the
  # column was never added.
  def change
    remove_column :users, :openai_access_token, :text, if_exists: true
  end
end
