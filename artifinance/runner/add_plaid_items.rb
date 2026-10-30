# Adds banks already linked in ~/banking-app to Sure, reusing their Plaid items (same client ID, same access
# token), so no new Plaid connection is made. stdin: {"items": [{"item_id", "name", "access_token"}]}.
# Never prints a token. Sure stores it in plaid_items.access_token, encrypted with the Keychain's AR keys.
input = JSON.parse($stdin.read)
family = Family.first or abort("no Sure family yet")
added = []

input.fetch("items").each do |item|
  next if PlaidItem.exists?(plaid_id: item.fetch("item_id"))

  plaid_item = family.plaid_items.create!(
    plaid_id: item.fetch("item_id"),
    access_token: item.fetch("access_token"),
    name: item.fetch("name").presence || "Bank",
    plaid_region: "us"
  )
  plaid_item.sync_later
  added << plaid_item.name
end

puts({ added: added }.to_json)
