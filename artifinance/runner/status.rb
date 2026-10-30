# Banks, accounts and the last syncs, without any secret.
family = Family.first or (puts({ family: nil }.to_json) && exit)
last = ->(s) { s && { status: s.status, at: s.completed_at || s.created_at, error: s.error.presence }.compact }
puts({
  banks: family.plaid_items.map { |i| { name: i.name, status: i.status, last_sync: last.(i.syncs.ordered.first) } },
  accounts: family.accounts.where(status: "active").order(:accountable_type, :name).map { |a|
    { name: a.name, type: a.accountable_type, balance: a.balance.to_f, transactions: a.entries.where(entryable_type: "Transaction").count }
  },
  family_last_sync: last.(family.syncs.ordered.first)
}.to_json)
