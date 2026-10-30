# Velocity: how fast money moves through your cash accounts, and whether you spend above your means.
#
# Rent counts at your share: each rent payment is split in Sure itself (MoneyRentSplit), so this page reads the
# split parts like every other Sure page, and leaves the roommate's share and their Venmo out of money in and out. "Within your means" is judged on a normal month at
# your current pay, which assumes the paychecks continue; the last full months are shown as they happened.
#
# Two views, on purpose:
# - Cash flow (checking/savings): money in vs money out of your cash accounts. Moves between your own cash
#   accounts don't count. Card payments do count as money out, because that's when card spending leaves your
#   cash. This view is complete even for cards that aren't in Sure (Wells Fargo, Amex, Bilt...).
# - Spending (all accounts): purchases by category and merchant, refunds netted out, transfers and card
#   payments matched between your own accounts left out (Sure's own rules for what counts).
class VelocityController < ApplicationController
  MONTHS = 12

  def show
    @family = Current.family
    @forecast = MoneyForecast.new(@family)
    @months = (0..MONTHS).map { |i| @forecast.today.beginning_of_month << (MONTHS - i) }
    @full_months = @months[0...-1]
    @cash = cash_flow
    @balances = average_cash_balances
    @cash_now = accounts_total("Depository")
    @card_debt = accounts_total("CreditCard")
    @categories = spending_by("category")
    @merchants = spending_by("merchant", limit: 15)
    @spend_by_month = @months.index_with { |m| @categories.sum { |row| row[:months][m] || 0 } }
    @kpi = kpis
    @breadcrumbs = [ [ "Home", root_path ], [ "Velocity", nil ] ]
  end

  private
    def conn
      ActiveRecord::Base.connection
    end

    def rows(sql, *binds)
      conn.select_all(ActiveRecord::Base.sanitize_sql_array([ sql, *binds ])).to_a
    end

    def base_sql
      <<~SQL
        FROM entries e
        JOIN transactions t ON e.entryable_type = 'Transaction' AND e.entryable_id = t.id
        JOIN accounts a ON a.id = e.account_id
        LEFT JOIN categories c ON c.id = t.category_id
        LEFT JOIN categories pc ON pc.id = c.parent_id
        WHERE a.family_id = :family AND a.status = 'active' AND NOT e.excluded
          AND e.date >= :from
      SQL
    end

    def binds
      { family: @family.id, from: @months.first }
    end

    # Money in / out of cash accounts per month. A transfer whose other side is also a cash account is internal.
    def cash_flow
      sql = <<~SQL
        SELECT date_trunc('month', e.date)::date AS month,
          SUM(CASE WHEN e.amount < 0 THEN -e.amount ELSE 0 END) AS money_in,
          SUM(CASE WHEN e.amount < 0 AND COALESCE(pc.name, c.name) = 'Income' THEN -e.amount ELSE 0 END) AS income,
          SUM(CASE WHEN e.amount > 0 THEN e.amount ELSE 0 END) AS money_out,
          SUM(CASE WHEN e.amount > 0 AND (t.kind = 'cc_payment' OR COALESCE(pc.name, c.name) = 'Loan Payments') THEN e.amount ELSE 0 END) AS card_payments
        #{base_sql}
          AND a.accountable_type = 'Depository'
          AND COALESCE(t.extra -> 'money_app_rent' ->> 'role', '') NOT IN ('roommate_share', 'roommate_venmo')
          AND NOT EXISTS (
            SELECT 1 FROM transfers tr
            JOIN transactions t2 ON t2.id = CASE WHEN tr.inflow_transaction_id = t.id THEN tr.outflow_transaction_id ELSE tr.inflow_transaction_id END
            JOIN entries e2 ON e2.entryable_type = 'Transaction' AND e2.entryable_id = t2.id
            JOIN accounts a2 ON a2.id = e2.account_id
            WHERE (tr.inflow_transaction_id = t.id OR tr.outflow_transaction_id = t.id)
              AND tr.status <> 'rejected' AND a2.accountable_type = 'Depository')
        GROUP BY 1
      SQL
      by_month = rows(sql, binds).index_by { |r| r["month"].to_date }
      @months.index_with do |m|
        r = by_month[m] || {}
        %w[money_in income money_out card_payments].index_with { |k| r[k].to_d }.symbolize_keys
      end
    end

    # Average end-of-day total of cash accounts, per month (Sure keeps one balance row per account per day).
    def average_cash_balances
      sql = <<~SQL
        SELECT date_trunc('month', d.date)::date AS month, AVG(d.total) AS avg_balance FROM (
          SELECT b.date, SUM(b.end_balance) AS total FROM balances b JOIN accounts a ON a.id = b.account_id
          WHERE a.family_id = :family AND a.status = 'active' AND a.accountable_type = 'Depository' AND b.date >= :from
          GROUP BY b.date) d
        GROUP BY 1
      SQL
      rows(sql, binds).to_h { |r| [ r["month"].to_date, r["avg_balance"].to_d ] }
    end

    def accounts_total(type)
      @family.accounts.where(status: "active", accountable_type: type).sum(:balance).to_d
    end

    # Net spending (purchases minus refunds) by category or merchant per month, on every account.
    # Income, and the transfer kinds Sure leaves out of budgets, aren't spending.
    def spending_by(what, limit: nil)
      label = what == "category" ? "COALESCE(pc.name, c.name, 'Uncategorized')" :
        "COALESCE(m.name, e.name)"
      excluded = Transaction::BUDGET_EXCLUDED_KINDS.map { |k| conn.quote(k) }.join(", ")
      sql = <<~SQL
        SELECT #{label} AS label, date_trunc('month', e.date)::date AS month, SUM(e.amount) AS total
        #{base_sql.sub("LEFT JOIN categories c", "LEFT JOIN merchants m ON m.id = t.merchant_id\nLEFT JOIN categories c")}
          AND t.kind NOT IN (#{excluded})
          AND COALESCE(pc.name, c.name, '') <> 'Income'
        GROUP BY 1, 2
      SQL
      grouped = rows(sql, binds).group_by { |r| r["label"] }.map do |name, rs|
        months = rs.to_h { |r| [ r["month"].to_date, r["total"].to_d ] }
        { name: name, months: months, total: @full_months.sum { |m| months[m] || 0 } }
      end
      grouped.select! { |g| g[:total] > 0 || g[:months].values.any?(&:positive?) }
      grouped.sort_by! { |g| -g[:total] }
      limit ? grouped.first(limit) : grouped
    end

    def kpis
      nm = @forecast.normal_month
      last3 = @full_months.last(3)
      avg = ->(key) { last3.sum { |m| @cash[m][key] } / 3 }
      avg_bal = last3.filter_map { |m| @balances[m] }
      avg_bal = avg_bal.any? ? avg_bal.sum / avg_bal.size : @cash_now
      days = last3.sum { |m| m.end_of_month.day } / 3.0
      money_out = avg.(:money_out)
      {
        months: last3, nm: nm,
        actual_in: avg.(:money_in), actual_income: avg.(:income), actual_out: money_out,
        actual_net: avg.(:money_in) - money_out,
        spending: last3.sum { |m| @spend_by_month[m] } / 3,
        runway_no_income: nm[:out].positive? ? @cash_now / nm[:out] : nil,
        runway_with_income: nm[:left].negative? ? @cash_now / -nm[:left] : nil,
        turnover: avg_bal.positive? ? money_out / avg_bal : nil,
        days_held: money_out.positive? ? avg_bal / (money_out / days.to_d) : nil,
        avg_balance: avg_bal,
        above_means: nm[:left].negative?
      }
    end
end
