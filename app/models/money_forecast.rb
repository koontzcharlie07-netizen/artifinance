# Checking-account forecast from live Sure data, recomputed on every page load (so after every sync).
# Used by /forecast (day-by-day projection) and /velocity (normal month, rent netting, runway).
#
# Patterns are learned from the transactions themselves, never typed in:
# - paychecks: Income deposits that repeat at a steady amount (semi-monthly 15th + month-end, or every N days)
# - rent: the Mortgage / Rent payment, and the roommate's Venmo of ~half the rent that lands a few days around it
# - Apple Card: the imported balance is this month's statement, due at the end of next month
# - other cards: autopay day from past payments; statement close day found by matching a past payment to charges
# - recurring: the same merchant and amount about a month apart; everything else runs at the recent typical rate,
#   with one-off purchases ($300 and up, not recurring) set aside
class MoneyForecast
  CUSHION = 1_000
  HORIZON_DAYS = 90
  ONE_OFF = 300
  WINDOW_DAYS = 90
  DAYS_PER_MONTH = 365.25 / 12

  Event = Struct.new(:date, :name, :amount, :group, :basis, :verified, keyword_init: true) # amount: + into checking
  Day = Struct.new(:date, :balance, :balance_high, :events, keyword_init: true)
  Assumption = Struct.new(:text, :source, :verified, keyword_init: true)

  attr_reader :family, :today, :start_balance, :days, :events, :events_high, :assumptions, :paychecks, :rent,
              :recurring, :cards, :everyday_daily, :one_offs, :normal_month

  def initialize(family, today: nil)
    @family = family
    @today = today || Time.current.in_time_zone(family.timezone.presence || "America/New_York").to_date
    @assumptions = []
    load_history
    @start_balance = checking_accounts.sum { |a| a.balance.to_d }
    @paychecks = detect_paychecks
    @rent = detect_rent
    @recurring = detect_recurring
    @everyday_daily = everyday_rate
    @one_offs = detect_one_offs
    @cards = card_models
    build_events
    project
    @normal_month = build_normal_month
  end

  def end_date
    (today + HORIZON_DAYS).end_of_month
  end

  def lowest(high: false)
    days.min_by { |d| high ? d.balance_high : d.balance }
  end

  def days_below(limit, high: false)
    days.count { |d| (high ? d.balance_high : d.balance) < limit }
  end

  def big_items(min = 500)
    events.select { |e| e.amount.abs >= min }
  end

  # If a paycheck that shares its day with big bills posted a day late: the worst such day.
  def paycheck_late_risk
    days.filter_map do |d|
      pay = d.events.select { |e| e.group == :paycheck }.sum(&:amount)
      [ d, d.balance - pay ] if pay.positive? && d.events.any? { |e| e.amount <= -1_000 }
    end.min_by(&:last)
  end

  # Roommate Venmos matched to past rent payments: [{date:, amount:, rent_date:}]. The forecast reads payments as
  # the bank sees them (a split rent payment counts once, at its full amount), so this finds them either way.
  def roommate_history
    rent ? rent[:matches] : []
  end

  private
    # -- history ------------------------------------------------------------------------------------------------

    def checking_accounts
      @checking_accounts ||= family.accounts.where(status: "active", accountable_type: "Depository").to_a
    end

    def load_history
      sql = <<~SQL
        SELECT e.id, e.date, e.amount, e.name, e.account_id, a.accountable_type AS account_type, a.name AS account_name,
          t.kind, COALESCE(pc.name, c.name) AS category, m.name AS merchant,
          (SELECT e2.account_id FROM transfers tr
             JOIN entries e2 ON e2.entryable_type = 'Transaction'
              AND e2.entryable_id = CASE WHEN tr.inflow_transaction_id = t.id THEN tr.outflow_transaction_id ELSE tr.inflow_transaction_id END
           WHERE (tr.inflow_transaction_id = t.id OR tr.outflow_transaction_id = t.id) AND tr.status <> 'rejected' LIMIT 1) AS other_account_id
        FROM entries e
        JOIN transactions t ON e.entryable_type = 'Transaction' AND e.entryable_id = t.id
        JOIN accounts a ON a.id = e.account_id
        LEFT JOIN categories c ON c.id = t.category_id
        LEFT JOIN categories pc ON pc.id = c.parent_id
        LEFT JOIN merchants m ON m.id = t.merchant_id
        WHERE a.family_id = :family AND a.status = 'active' AND e.parent_entry_id IS NULL
          AND (NOT e.excluded OR EXISTS (SELECT 1 FROM entries ce WHERE ce.parent_entry_id = e.id))
          AND e.date >= :from AND e.date <= :today
        ORDER BY e.date, e.id
      SQL
      rows = ActiveRecord::Base.connection.select_all(
        ActiveRecord::Base.sanitize_sql_array([ sql, { family: family.id, from: today - 400, today: today } ])
      )
      @history = rows.map do |r|
        r.symbolize_keys.merge(date: r["date"].to_date, amount: r["amount"].to_d, key: key_for(r["merchant"].presence || r["name"]))
      end
    end

    def key_for(text)
      text.to_s.downcase.split(/\*{2,}/).first.to_s.gsub(/[^a-z& ]+/, " ").squeeze(" ").strip
    end

    def checking_rows
      @history.select { |r| r[:account_type] == "Depository" }
    end

    def internal_transfer?(r)
      r[:other_account_id].present?
    end

    # -- paychecks ----------------------------------------------------------------------------------------------

    def detect_paychecks
      streams = checking_rows.select { |r| r[:amount].negative? && r[:category] == "Income" && -r[:amount] >= 500 }
                             .group_by { |r| r[:key] }
      streams.filter_map do |key, rows|
        recent = rows.last(4)
        amounts = recent.map { |r| -r[:amount] }
        next if recent.size < 2 || recent.last[:date] < today - 35
        next if amounts.max > amounts.min * 1.1 # irregular amounts (reimbursement batches, bonuses)

        mid_or_end = recent.all? { |r| r[:date].day.between?(12, 16) || r[:date].day >= 27 || r[:date].day <= 2 }
        rule = mid_or_end ? :semi_monthly : :every
        gaps = recent.each_cons(2).map { |a, b| (b[:date] - a[:date]).to_i }.sort
        interval = gaps[gaps.size / 2]
        { name: display_name(recent.last).sub(/\s*payroll.*/i, ""), key: key, amount: amounts.last, last: recent.last[:date], rule: rule,
          interval: interval, per_month: rule == :semi_monthly ? 2 : DAYS_PER_MONTH / interval,
          dates: recent.map { |r| r[:date] } }
      end
    end

    def display_name(row)
      (row[:merchant].presence || row[:name].to_s.split(/\*{2,}/).first.to_s.split(" - ").last).to_s.strip.titleize
    end

    def paycheck_dates(stream)
      if stream[:rule] == :semi_monthly
        months = (today.beginning_of_month..end_date).map(&:beginning_of_month).uniq
        months.flat_map { |m| [ Date.new(m.year, m.month, 15), m.end_of_month ] }.map { |d| business_day_before(d) }
              .select { |d| d > today && d <= end_date && d > stream[:last] + 5 }
      else
        d = stream[:last] + stream[:interval]
        out = []
        while d <= end_date
          out << d if d > today
          d += stream[:interval]
        end
        out
      end
    end

    def business_day_before(d)
      d -= 1 while d.saturday? || d.sunday?
      d
    end

    def business_day_after(d)
      d += 1 while d.saturday? || d.sunday?
      d
    end

    # -- rent and the roommate's share ----------------------------------------------------------------------------

    def detect_rent
      rows = checking_rows.select { |r| r[:amount].positive? && r[:category] == "Mortgage / Rent" }
      return nil if rows.empty? || rows.last[:date] < today - 40

      last = rows.last
      month_end = rows.last(3).all? { |r| r[:date].day >= 28 || r[:date] == r[:date].end_of_month }
      inflows = checking_rows.select { |r| r[:amount].negative? && r[:category] != "Income" && !internal_transfer?(r) }
      matches = rows.filter_map do |rent_row|
        venmo = inflows.find do |r|
          (r[:date] - rent_row[:date]).to_i.between?(-3, 1) && (-r[:amount]).between?(rent_row[:amount] * 0.35, rent_row[:amount] * 0.65)
        end
        venmo && { date: venmo[:date], amount: -venmo[:amount], rent_date: rent_row[:date], entry_id: venmo[:id],
                   rent_label: rent_row[:merchant].presence || rent_row[:name] }
      end
      recent_matches = matches.select { |m| m[:rent_date] >= rows.last(4).first[:date] }
      roommate = recent_matches.size >= 3 ? recent_matches.map { |m| m[:amount] }.min : 0.to_d
      { name: display_name(last), amount: last[:amount], month_end: month_end, day: last[:date].day, last: last[:date],
        dates: rows.last(4).map { |r| r[:date] }, roommate: roommate, matches: matches,
        matched: recent_matches.size, checked: rows.last(4).size }
    end

    def rent_dates
      return [] unless rent
      months = (today.beginning_of_month..end_date).map(&:beginning_of_month).uniq
      months.map { |m| rent[:month_end] ? m.end_of_month : Date.new(m.year, m.month, [ rent[:day], m.end_of_month.day ].min) }
            .select { |d| d > today && d <= end_date && d > rent[:last] + 5 }
    end

    # -- recurring charges ------------------------------------------------------------------------------------------

    def detect_recurring
      candidates = @history.select do |r|
        r[:amount].positive? && !internal_transfer?(r) && r[:kind] != "cc_payment" && r[:category] != "Mortgage / Rent" &&
          !(r[:kind] == "funds_movement" && r[:account_type] == "CreditCard") && r[:date] >= today - 150
      end
      candidates.group_by { |r| [ r[:account_id], r[:key], r[:amount] ] }.filter_map do |(_, _, amount), rows|
        next if rows.size < 2 || rows.last[:date] < today - 40
        # monthly now: the latest gap is about a month (a skipped month earlier doesn't matter)
        next unless (rows[-1][:date] - rows[-2][:date]).to_i.between?(25, 35)

        { name: display_name(rows.last), amount: amount, day: rows.last[:date].day, last: rows.last[:date],
          account_id: rows.last[:account_id], account_name: rows.last[:account_name],
          checking: rows.last[:account_type] == "Depository", count: rows.size, ids: rows.map { |r| r[:id] } }
      end
    end

    def recurring_ids
      @recurring_ids ||= recurring.flat_map { |s| s[:ids] }.to_set
    end

    def recurring_dates(stream, from, to)
      (from.beginning_of_month..to).map(&:beginning_of_month).uniq.filter_map do |m|
        d = Date.new(m.year, m.month, [ stream[:day], m.end_of_month.day ].min)
        d if d > from && d <= to && d > stream[:last] + 5
      end
    end

    # -- typical rates and one-offs ---------------------------------------------------------------------------------

    def spend_rows(account_ids)
      @history.select do |r|
        account_ids.include?(r[:account_id]) && !internal_transfer?(r) &&
          !%w[cc_payment].include?(r[:kind]) && !(r[:kind] == "funds_movement" && r[:account_type] == "CreditCard") &&
          r[:category] != "Mortgage / Rent" && r[:category] != "Income" &&
          (r[:account_type] != "Depository" || r[:amount].positive?) # money coming into checking isn't a refund
      end
    end

    def one_off?(r, rows)
      return false if recurring_ids.include?(r[:id])
      return true if r[:amount] >= ONE_OFF
      # a refund of a one-off purchase from the same merchant
      r[:amount].negative? && rows.any? { |p| same_merchant?(p, r) && p[:amount] >= ONE_OFF && p[:date] <= r[:date] }
    end

    # Refunds often carry a longer merchant text ("... (return)"), so compare the first two words.
    def same_merchant?(a, b)
      a[:key].split.first(2) == b[:key].split.first(2)
    end

    def typical_daily(account_ids)
      rows = spend_rows(account_ids)
      return [ 0.to_d, today, 0 ] if rows.empty?
      from = [ rows.first[:date], today - WINDOW_DAYS + 1 ].max
      window = rows.select { |r| r[:date] >= from }
      kept = window.reject { |r| one_off?(r, window) || recurring_ids.include?(r[:id]) }
      days = (today - from).to_i + 1
      [ kept.sum { |r| r[:amount] } / days, from, days ]
    end

    def everyday_rate
      ids = checking_accounts.map(&:id)
      rate, from, days = typical_daily(ids)
      @everyday_window = [ from, days ]
      rate.positive? ? rate : 0.to_d
    end

    def detect_one_offs
      ids = family.accounts.where(status: "active").pluck(:id)
      rows = spend_rows(ids).select { |r| r[:date] > today - WINDOW_DAYS }
      rows.select { |r| r[:amount] >= ONE_OFF && !recurring_ids.include?(r[:id]) }.map do |r|
        refunded = rows.select { |x| same_merchant?(x, r) && x[:amount].negative? && x[:date] >= r[:date] }.sum { |x| -x[:amount] }
        r.merge(refunded: [ refunded, r[:amount] ].min)
      end
    end

    # -- cards ------------------------------------------------------------------------------------------------------

    def apple_account_id
      Setting["money_app_apple_card_account_id"]
    end

    def card_models
      family.accounts.where(status: "active", accountable_type: "CreditCard").map do |card|
        rate, from, days = typical_daily([ card.id ])
        card_recurring = recurring.select { |s| s[:account_id] == card.id }
        model = { account: card, name: card.name, balance: card.balance.to_d, rate: rate, window_from: from, window_days: days,
                  recurring: card_recurring }
        card.id == apple_account_id ? model.merge(apple_model(card)) : model.merge(autopay_model(card))
      end
    end

    def payments_from_checking(card)
      checking_rows.select do |r|
        r[:amount].positive? && (r[:other_account_id] == card.id ||
          (card.id == apple_account_id && r[:kind] == "cc_payment" && r[:name].to_s =~ /apple ?card|gsbank/i))
      end
    end

    def apple_model(card)
      paid = payments_from_checking(card)
      since = (today << 6).beginning_of_month
      months = ((today.year * 12 + today.month) - (since.year * 12 + since.month)) + 1
      high_monthly = paid.select { |r| r[:date] >= since }.sum { |r| r[:amount] } / months
      as_of = Setting["money_app_apple_card_balance_as_of"].to_s.split(":").first
      this_month = paid.select { |r| r[:date] >= today.beginning_of_month }
      { kind: :apple, high_monthly: high_monthly, high_since: since, high_months: months, balance_as_of: as_of,
        paid_this_month: this_month }
    end

    def autopay_model(card)
      paid = payments_from_checking(card).last(3)
      pay_day = paid.any? ? paid.map { |r| r[:date].day }.sort[paid.size / 2] : 8
      card_payments = @history.select { |r| r[:account_id] == card.id && r[:amount].negative? && internal_transfer?(r) }
      charges = @history.select { |r| r[:account_id] == card.id && !internal_transfer?(r) && r[:kind] != "funds_movement" }
      close_day, proof = nil, nil
      card_payments.reverse_each do |p|
        fits = (1..28).select do |c|
          start = close_on(p[:date] << 2, c) + 1
          finish = close_on(p[:date] << 1, c)
          next false if charges.none? { |r| r[:date] < start } # history must reach back past the period
          (charges.select { |r| r[:date].between?(start, finish) }.sum { |r| r[:amount] } - (-p[:amount])).abs < 0.02
        end
        next if fits.empty?
        close_day = fits[(fits.size - 1) / 2]
        proof = { payment: p, start: close_on(p[:date] << 2, close_day) + 1, finish: close_on(p[:date] << 1, close_day) }
        break
      end
      { kind: :autopay, pay_day: pay_day, payments: paid, close_day: close_day || [ pay_day + 5, 28 ].min,
        close_verified: !close_day.nil?, proof: proof, charges: charges }
    end

    def close_on(month_date, day)
      Date.new(month_date.year, month_date.month, [ day, month_date.end_of_month.day ].min)
    end

    # Card charges between two dates: what's already charged, plus the typical rate and recurring charges after today.
    def card_charges(card, from, to, rate)
      actual = card[:charges].to_a.select { |r| r[:date].between?(from, [ to, today ].min) }.sum { |r| r[:amount] }
      future_from = [ from, today + 1 ].max
      future_days = future_from > to ? 0 : (to - future_from).to_i + 1
      subs = card[:recurring].sum { |s| recurring_dates(s, future_from - 1, to).size * s[:amount] }
      actual + rate * future_days + subs
    end

    # -- events and projection ----------------------------------------------------------------------------------------

    def build_events
      base = []
      paychecks.each do |s|
        basis = s[:rule] == :semi_monthly ? "15th and month-end, weekends moved to the Friday before" : "every #{s[:interval]} days"
        paycheck_dates(s).each do |d|
          base << Event.new(date: d, name: "#{s[:name]} paycheck", amount: s[:amount], group: :paycheck,
                            basis: "#{basis}; amount = last check (#{s[:last].strftime('%b %-d')})", verified: true)
        end
      end
      rent_dates.each do |d|
        share = rent[:amount] - rent[:roommate]
        label = rent[:roommate].positive? ? "#{rent[:name]} rent (#{money(rent[:amount])}; your share #{money(share)})" : "#{rent[:name]} rent"
        base << Event.new(date: d, name: label, amount: -rent[:amount], group: :rent,
                          basis: rent[:month_end] ? "last day of each month, like the last 3" : "day #{rent[:day]} each month", verified: true)
        next unless rent[:roommate].positive?
        base << Event.new(date: d - 1, name: "Roommate's rent share (Venmo)", amount: rent[:roommate], group: :roommate,
                          basis: "~#{money(rent[:roommate])} came in around #{rent[:matched]} of the last #{rent[:checked]} rent payments", verified: false)
      end
      recurring.select { |s| s[:checking] }.each do |s|
        recurring_dates(s, today, end_date).each do |d|
          base << Event.new(date: d, name: s[:name], amount: -s[:amount], group: :recurring,
                            basis: "monthly, #{s[:count]} times, last #{s[:last].strftime('%b %-d')}", verified: true)
        end
      end
      @events = (base + card_events(high: false)).select { |e| e.date > today && e.date <= end_date }.sort_by { |e| [ e.date, -e.amount ] }
      @events_high = (base + card_events(high: true)).select { |e| e.date > today && e.date <= end_date }.sort_by { |e| [ e.date, -e.amount ] }
    end

    def card_events(high:)
      cards.flat_map do |card|
        card[:kind] == :apple ? apple_events(card, high) : autopay_events(card)
      end
    end

    def apple_events(card, high)
      rate = high ? card[:high_monthly] / DAYS_PER_MONTH : card[:rate]
      out = []
      month = today.beginning_of_month
      while month.end_of_month.next_month <= end_date.end_of_month
        due = month.next_month.end_of_month
        if month == today.beginning_of_month
          rest = (month.end_of_month - today).to_i
          amount = card[:balance] + rate * rest
          basis = "#{money(card[:balance])} owed (imported statement, as of #{card[:balance_as_of]}) + #{rest} more days at #{money(rate, 2)}/day"
        else
          amount = rate * month.end_of_month.day
          basis = "estimate: #{month.strftime('%B')} at #{money(rate, 2)}/day"
        end
        out << Event.new(date: due, name: "Apple Card #{month.strftime('%B')} statement", amount: -amount.round(2), group: :card,
                         basis: basis, verified: false) if due <= end_date
        month = month.next_month
      end
      out
    end

    def autopay_events(card)
      out = []
      month = today.beginning_of_month
      while month <= end_date
        pay = business_day_after(Date.new(month.year, month.month, [ card[:pay_day], month.end_of_month.day ].min))
        if pay > today && pay <= end_date && card[:payments].none? { |p| p[:date] >= month && p[:date] <= month.end_of_month }
          finish = close_on(pay << 1, card[:close_day])
          start = close_on(pay << 2, card[:close_day]) + 1
          amount = card_charges(card, start, finish, card[:rate])
          known = finish <= today
          out << Event.new(date: pay, name: "#{card[:name]} autopay (statement #{start.strftime('%b %-d')}–#{finish.strftime('%b %-d')})",
                           amount: -amount.round(2), group: :card,
                           basis: known ? "charges in that period (all posted)" : "charges so far + typical #{money(card[:rate], 2)}/day + subscriptions",
                           verified: known && card[:close_verified])
        end
        month = month.next_month
      end
      out
    end

    def project
      bal = start_balance
      bal_high = start_balance
      by_day = events.group_by(&:date)
      by_day_high = events_high.group_by(&:date)
      @days = ((today + 1)..end_date).map do |d|
        bal += by_day.fetch(d, []).sum(&:amount) - everyday_daily
        bal_high += by_day_high.fetch(d, []).sum(&:amount) - everyday_daily
        Day.new(date: d, balance: bal.round(2), balance_high: bal_high.round(2), events: by_day.fetch(d, []))
      end
    end

    # -- a normal month ------------------------------------------------------------------------------------------------

    def build_normal_month
      take_home = paychecks.sum { |s| s[:amount] * s[:per_month] }
      rent_share = rent ? rent[:amount] - rent[:roommate] : 0
      bills = recurring.sum { |s| s[:amount] }
      card_typical = cards.to_h { |c| [ c[:name], c[:rate] * DAYS_PER_MONTH ] }
      everyday = everyday_daily * DAYS_PER_MONTH
      out = rent_share + bills + card_typical.values.sum + everyday
      apple = cards.find { |c| c[:kind] == :apple }
      out_high = apple ? out - card_typical[apple[:name]] + apple[:high_monthly] : out
      { take_home: take_home, rent_share: rent_share, rent: rent&.dig(:amount), roommate: rent&.dig(:roommate),
        bills: bills, cards: card_typical, everyday: everyday, out: out, left: take_home - out,
        savings_rate: take_home.positive? ? (take_home - out) / take_home : nil,
        out_high: out_high, left_high: take_home - out_high,
        one_offs: one_offs.sum { |o| o[:amount] - o[:refunded] } }
    end

    def money(v, digits = 0)
      ActiveSupport::NumberHelper.number_to_currency(v, precision: digits)
    end

    public

    # The assumptions behind the numbers, each marked verified (seen in the data) or inferred.
    def assumption_list
      list = []
      list << Assumption.new(text: "Starting balance #{money(start_balance, 2)}: " + checking_accounts.map { |a| "#{a.name} #{money(a.balance, 2)}" }.join(" + "),
                             source: "balances from Plaid at the last sync", verified: true)
      paychecks.each do |s|
        list << Assumption.new(text: "#{s[:name]}: #{money(s[:amount], 2)} #{s[:rule] == :semi_monthly ? 'on the 15th and the last day of the month (weekends: the Friday before)' : "every #{s[:interval]} days"}",
                               source: "last checks #{s[:dates].map { |d| d.strftime('%b %-d') }.join(', ')}; the weekend rule is inferred", verified: true)
      end
      list << Assumption.new(text: "No paycheck found in the last 35 days", source: "income would be $0 in the forecast", verified: false) if paychecks.empty?
      if rent
        list << Assumption.new(text: "#{rent[:name]} #{money(rent[:amount])} #{rent[:month_end] ? 'on the last day of each month' : "on day #{rent[:day]}"}",
                               source: "last payments #{rent[:dates].map { |d| d.strftime('%b %-d') }.join(', ')}", verified: true)
        if rent[:roommate].positive?
          list << Assumption.new(text: "Your rent is #{money(rent[:amount] - rent[:roommate])}: a ~#{money(rent[:roommate])} Venmo (your roommate's share) comes in the day before",
                                 source: "a Venmo of #{money(rent[:matches].last(4).map { |m| m[:amount] }.min)}–#{money(rent[:matches].last(4).map { |m| m[:amount] }.max)} landed 0–3 days around #{rent[:matched]} of the last #{rent[:checked]} rent payments; that it's your roommate's share is your figure", verified: false)
        end
      end
      cards.each do |c|
        if c[:kind] == :apple
          list << Assumption.new(text: "Apple Card: #{money(c[:balance], 2)} owed (imported, as of #{c[:balance_as_of]}) + the rest of this month is due at the end of next month",
                                 source: "statement balance from your import; due date is Apple's rule. Assumes last month's statement is paid" +
                                         (c[:paid_this_month].any? ? " (payments this month: #{c[:paid_this_month].map { |p| "#{p[:date].strftime('%b %-d')} #{money(p[:amount], 2)}" }.join(', ')})" : ""), verified: true)
          list << Assumption.new(text: "Apple Card everyday spending #{money(c[:rate], 2)}/day (#{money(c[:rate] * DAYS_PER_MONTH)}/month)",
                                 source: "#{c[:window_from].strftime('%b %-d')}–#{today.strftime('%b %-d')} (#{c[:window_days]} days of imported statements), one-offs of #{money(ONE_OFF)}+ left out", verified: false)
          list << Assumption.new(text: "Higher-spending line: Apple Card at #{money(c[:high_monthly])}/month",
                                 source: "what you paid Apple from checking, #{c[:high_since].strftime('%b %Y')}–#{today.strftime('%b %Y')} averaged", verified: true)
        else
          list << Assumption.new(text: "#{c[:name]}: autopay pays the full statement on day #{c[:pay_day]} (next business day)",
                                 source: "past autopays #{c[:payments].map { |p| p[:date].strftime('%b %-d') }.join(', ')}; Plaid gives no due date without the liabilities product", verified: false)
          list << Assumption.new(text: "#{c[:name]} statements close around day #{c[:close_day]}",
                                 source: c[:proof] ? "the #{c[:proof][:payment][:date].strftime('%b %-d')} payment of #{money(-c[:proof][:payment][:amount], 2)} equals the charges from #{c[:proof][:start].strftime('%b %-d')} to #{c[:proof][:finish].strftime('%b %-d')}" : "guessed: 5 days after the autopay",
                                 verified: c[:close_verified])
          list << Assumption.new(text: "#{c[:name]} everyday spending #{money(c[:rate], 2)}/day besides its subscriptions",
                                 source: "#{c[:window_from].strftime('%b %-d')}–#{today.strftime('%b %-d')}, one-offs and subscriptions left out", verified: false)
        end
      end
      recurring.each do |s|
        list << Assumption.new(text: "#{s[:name]} #{money(s[:amount], 2)} on day #{s[:day]} (#{s[:account_name]})",
                               source: "same amount #{s[:count]} times about a month apart, last #{s[:last].strftime('%b %-d')}", verified: true)
      end
      list << Assumption.new(text: "Everyday checking spending #{money(everyday_daily, 2)}/day (#{money(everyday_daily * DAYS_PER_MONTH)}/month), every day",
                             source: "debit purchases and one-off Venmo, #{@everyday_window[0].strftime('%b %-d')}–#{today.strftime('%b %-d')}; one-offs left out", verified: false)
      list << Assumption.new(text: "Left out: reimbursements, other Venmo coming in, refunds, tax refunds, one-off purchases",
                             source: "irregular, so not projected", verified: false)
      list
    end
end
