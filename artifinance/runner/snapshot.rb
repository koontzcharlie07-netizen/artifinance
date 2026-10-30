# Key numbers, to compare before and after a change: forecast, normal month, income statement, balances.
f = Family.first
fc = MoneyForecast.new(f)
is = f.income_statement
months = [[2026, 9], [2026, 10]].map do |y, m|
  period = Period.custom(start_date: Date.new(y, m, 1), end_date: Date.new(y, m, 1).end_of_month)
  inc = is.income_totals(period: period); exp = is.expense_totals(period: period)
  ["#{y}-#{m}", { income: inc.total.to_f, expense: exp.total.to_f,
                  rent: exp.category_totals.select { |c| c.category.name == "Mortgage / Rent" }.sum { |c| c.total.to_f } }]
end.to_h
low = fc.lowest
puts({ lowest: [low.date.to_s, low.balance.to_f], lowest_high: fc.lowest(high: true).balance_high.to_f,
       end: fc.days.last.balance.to_f, events: fc.events.size,
       normal_month: fc.normal_month.slice(:take_home, :out, :left, :savings_rate).transform_values { |v| v.to_f.round(2) },
       months: months, balances: f.accounts.order(:name).map { |a| [a.name, a.balance.to_f] },
       transactions: Entry.count, splits: MoneyRentSplit.history(f).size }.to_json)
