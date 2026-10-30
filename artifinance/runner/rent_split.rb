# Splits rent payments into your share and the roommate's share (see MoneyRentSplit); prints what it did.
family = Family.first or abort("no Sure family yet")
stats = MoneyRentSplit.new(family).apply!
puts stats.merge(history: MoneyRentSplit.history(family).map { |h| h.slice(:date, :rent, :roommate_part).transform_values(&:to_s) }).to_json
