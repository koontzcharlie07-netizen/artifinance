# Queues a sync of every bank in Sure (Plaid /transactions/sync from each item's own cursor) and of every
# account, like Sure's "Sync all". stdin {"check": true} only reports whether a sync is still running.
input = JSON.parse($stdin.read.presence || "{}")
family = Family.first or abort("no Sure family yet")
if input["check"]
  puts({ syncing: family.syncing? }.to_json)
else
  family.sync_later
  puts({ banks: family.plaid_items.active.map(&:name), wait: true }.to_json)
end
