# Per-account transaction counts, keyed like ~/banking-app (Plaid account ID; "import-apple-card"), and the
# Apple Card's net spending by month counted the way ~/banking-app does (payments and Daily Cash left out).
family = Family.first or abort("no Sure family yet")
apple_id = Setting["money_app_apple_card_account_id"]
out = {}
family.accounts.where(status: "active").each do |a|
  key = a.id == apple_id ? "import-apple-card" : (a.provider_account_for("PlaidAccount")&.plaid_id || a.plaid_account&.plaid_id || a.id)
  txns = a.entries.where(entryable_type: "Transaction", parent_entry_id: nil)
  row = { name: a.name, count: txns.count }
  if a.id == apple_id
    spend = txns.joins("JOIN transactions t ON t.id = entries.entryable_id")
                .where("t.kind NOT IN (?) AND t.transfer_id IS NULL", %w[funds_movement cc_payment one_time])
                .where.not(id: txns.joins("JOIN transactions t2 ON t2.id = entries.entryable_id JOIN transfers tr ON tr.inflow_transaction_id = t2.id OR tr.outflow_transaction_id = t2.id").select(:id))
                .group("to_char(entries.date, 'YYYY-MM')").sum(:amount)
    row[:net_spend] = spend.transform_values { |v| v.to_f.round(2) }
  end
  out[key] = row
end
# Spending on every account by month, counted like the Velocity page: no transfer kinds, no Income.
spend_sql = <<~SQL
  SELECT to_char(e.date, 'YYYY-MM') AS month, SUM(e.amount) AS total
  FROM entries e JOIN transactions t ON t.id = e.entryable_id AND e.entryable_type = 'Transaction'
  JOIN accounts a ON a.id = e.account_id LEFT JOIN categories c ON c.id = t.category_id LEFT JOIN categories pc ON pc.id = c.parent_id
  WHERE a.family_id = #{ActiveRecord::Base.connection.quote(family.id)} AND a.status = 'active' AND NOT e.excluded
    AND t.kind NOT IN ('funds_movement', 'cc_payment', 'one_time') AND COALESCE(pc.name, c.name, '') <> 'Income'
  GROUP BY 1
SQL
spending = ActiveRecord::Base.connection.select_all(spend_sql).to_h { |r| [ r["month"], r["total"].to_f.round(2) ] }
# Plaid transactions Sure paired as a transfer between your own accounts (~/banking-app may count them as spending).
paired_sql = <<~SQL
  SELECT e.external_id FROM entries e JOIN transactions t ON t.id = e.entryable_id AND e.entryable_type = 'Transaction'
  JOIN transfers tr ON (tr.inflow_transaction_id = t.id OR tr.outflow_transaction_id = t.id) AND tr.status <> 'rejected'
  WHERE e.source = 'plaid'
SQL
paired = ActiveRecord::Base.connection.select_values(paired_sql)
# Rent split on purpose (MoneyRentSplit): the roommate's share of each rent payment isn't spending in Sure.
roommate = MoneyRentSplit.history(family).map { |h| { date: h[:date].to_s, amount: h[:roommate_part].to_f, name: h[:name].to_s } }
puts({ accounts: out, spending: spending, paired: paired, roommate: roommate }.to_json)
