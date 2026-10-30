# Mirrors the Apple Card statements imported in ~/banking-app into a manual "Apple Card" credit card in Sure.
# stdin: {"balance": 1234.5|null, "as_of": "YYYY-MM-DD"|null, "transactions": [{id, date, name, merchant,
# amount, category, apple_category, kind}]}, the complete Apple Card set each time.
# Keyed by banking-app's transaction ID: re-running adds nothing twice, and rows removed there go here too.
# A category or merchant you change in Sure is kept: only what this script set last time gets updated.
SOURCE = "banking_app_apple_card".freeze
CATEGORY = {
  "Food & Drink" => "Food & Drink", "Transportation" => "Transportation", "Travel" => "Travel",
  "Shopping" => "Shopping", "Entertainment" => "Entertainment", "Medical" => "Healthcare",
  "Rent & Utilities" => "Utilities", "Services" => "Services", "Bank Fees" => "Fees",
  "Personal Care" => "Personal Care", "Home Improvement" => "Home Improvement", "Income" => "Income",
  "Loan Payments" => "Loan Payments"
}.freeze
APPLE = { "Grocery" => "Groceries", "Insurance" => "Insurance" }.freeze

input = JSON.parse($stdin.read)
family = Family.first or abort("no Sure family yet")
categories = family.categories.index_by(&:name)

account = Account.find_by(id: Setting["money_app_apple_card_account_id"], family_id: family.id)
unless account
  account = Account.create_and_sync(
    { family: family, name: "Apple Card", balance: 0, currency: "USD", accountable_type: "CreditCard",
      institution_name: "Apple Card (statement import)" },
    skip_initial_sync: true
  )
  Setting["money_app_apple_card_account_id"] = account.id
end

stats = Hash.new(0)
seen = []
ActiveRecord::Base.transaction do
  input.fetch("transactions").each do |row|
    seen << row["id"]
    entry = account.entries.find_or_initialize_by(external_id: row["id"], source: SOURCE)
    txn = entry.entryable || Transaction.new
    ours = txn.extra.is_a?(Hash) ? (txn.extra["money_app"] || {}) : {}

    category_name = APPLE[row["apple_category"]] || CATEGORY[row["category"]] || categories[row["category"]]&.name
    category = categories[category_name]
    merchant = row["merchant"].present? ? FamilyMerchant.find_or_create_by!(family: family, name: row["merchant"]) : nil

    entry.assign_attributes(date: row["date"], name: row["name"], amount: row["amount"].to_d, currency: "USD")
    txn.category = category if entry.new_record? || txn.category_id == ours["category_id"]
    txn.merchant = merchant if entry.new_record? || txn.merchant_id == ours["merchant_id"]
    txn.kind = row["kind"] if entry.new_record? || (txn.kind == ours["kind"] && txn.transfer.nil?)
    txn.extra = (txn.extra || {}).merge("money_app" => { "category_id" => txn.category_id,
                                                         "merchant_id" => txn.merchant_id, "kind" => txn.kind })
    entry.entryable = txn
    stats[entry.new_record? ? :added : (entry.changed? || txn.changed? ? :updated : :unchanged)] += 1
    entry.save!
  end

  gone = account.entries.where(source: SOURCE).where.not(external_id: seen)
  stats[:removed] = gone.count
  gone.destroy_all
end

# Statement balance from ~/banking-app (what you owe on its as-of date): Sure works balances forward from an
# opening balance, so that's set to the statement balance minus everything imported up to that date.
balance_key = "#{input['as_of']}:#{input['balance']}"
changed = stats[:added] + stats[:updated] + stats[:removed] > 0
if input["balance"] && (changed || Setting["money_app_apple_card_balance_as_of"] != balance_key)
  txns = account.entries.where(entryable_type: "Transaction")
  if (oldest = txns.minimum(:date))
    as_of = (Date.parse(input["as_of"].to_s) rescue Date.current)
    opening = input["balance"].to_d - txns.where("date <= ?", as_of).sum(:amount)
    result = Account::OpeningBalanceManager.new(account).set_opening_balance(balance: opening, date: oldest - 1)
    abort("Apple Card opening balance: #{result.error}") unless result.success?
    Setting["money_app_apple_card_balance_as_of"] = balance_key
    stats[:balance] = input["balance"]
    changed = true
  end
end

# Pair the card's payments with the USAA side, then recompute the card's balances.
family.auto_match_transfers!(account: account) if stats[:added] + stats[:updated] > 0
account.sync_later if changed

puts stats.merge(account_id: account.id, total: seen.size).to_json
