# Gives Sure's Plaid transactions ~/banking-app's categories (Plaid's, plus your rules there): the same Plaid
# transaction IDs on both sides. stdin: {"transactions": [{id, category, detailed}]}.
# Transfers and card payments become Sure transfer kinds, so neither app counts them as spending.
# What you change by hand in Sure is kept (Sure locks it); Sure's own automatic pick from Plaid is replaced.
CATEGORY = {
  "Income" => "Income", "Food & Drink" => "Food & Drink", "Shopping" => "Shopping",
  "Transportation" => "Transportation", "Travel" => "Travel", "Entertainment" => "Entertainment",
  "Medical" => "Healthcare", "Personal Care" => "Personal Care", "Home Improvement" => "Home Improvement",
  "Services" => "Services", "Bank Fees" => "Fees", "Loan Payments" => "Loan Payments",
  "Government & Non-Profit" => "Taxes"
}.freeze
KIND = { "Transfer In" => "funds_movement", "Transfer Out" => "funds_movement", "Credit Card Payment" => "cc_payment" }.freeze

input = JSON.parse($stdin.read)
family = Family.first or abort("no Sure family yet")
categories = family.categories.index_by(&:name)
rows = input.fetch("transactions").index_by { |r| r["id"] }
stats = Hash.new(0)

entries = Entry.joins(:account).where(accounts: { family_id: family.id }, entryable_type: "Transaction",
                                      source: "plaid", external_id: rows.keys).includes(:entryable)
ActiveRecord::Base.transaction do
  entries.each do |entry|
    row = rows[entry.external_id]
    txn = entry.entryable
    ours = (txn.extra || {})["money_app"] || {}
    name = row["category"] == "Rent & Utilities" ? (row["detailed"].to_s =~ /rent/i ? "Mortgage / Rent" : "Utilities") : CATEGORY[row["category"]]
    category_id = categories[name]&.id
    kind = KIND[row["category"]] || "standard"

    if !entry.user_modified? && !txn.locked?(:category_id)
      txn.category_id = category_id
    end
    # A transfer Sure matched between your own accounts keeps Sure's kinds.
    if txn.transfer.nil? && (txn.kind == "standard" || txn.kind == ours["kind"])
      txn.kind = kind
    end
    txn.extra = (txn.extra || {}).merge("money_app" => { "category_id" => txn.category_id, "kind" => txn.kind })
    stats[txn.changed? ? :updated : :unchanged] += 1
    txn.save!
  end
end

puts stats.merge(missing: rows.size - entries.size).to_json
