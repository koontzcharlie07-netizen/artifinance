class MoneyForecast
  CUSHION = 1_000
  HORIZON_DAYS = 90
  ONE_OFF = 300

  Event = Data.define(:date, :name, :amount, :group, :basis, :verified)
  Day = Data.define(:date, :balance, :balance_high, :events)
  Assumption = Data.define(:text, :source, :verified)

  attr_reader :today, :start_balance, :days, :events, :everyday_daily, :one_offs, :normal_month, :recurring

  def initialize(family, today: nil)
    payload = ArtifinanceCore.call("forecast", { family_id: family.id, today: today&.iso8601 }, timeout: 15)
    @today = Date.iso8601(payload.fetch("today"))
    @end_date = Date.iso8601(payload.fetch("end_date"))
    @start_balance = decimal(payload.fetch("start_balance"))
    @events = payload.fetch("events").map { |event| build_event(event) }
    @days = payload.fetch("days").map { |day| build_day(day) }
    @everyday_daily = decimal(payload.fetch("everyday_daily"))
    @one_offs = deep_value(payload.fetch("one_offs"))
    @normal_month = deep_value(payload.fetch("normal_month"))
    @recurring = deep_value(payload.fetch("recurring"))
    @assumptions = payload.fetch("assumptions").map { |item| Assumption.new(**deep_value(item)) }
    @big_items = payload.fetch("big_items").map { |event| build_event(event) }
    @lowest = build_day(payload.fetch("lowest"))
    @lowest_high = build_day(payload.fetch("lowest_high"))
    @paycheck_late_risk = if payload["paycheck_late_risk"]
      [ build_day(payload["paycheck_late_risk"].first), decimal(payload["paycheck_late_risk"].last) ]
    end
    @roommate_history = deep_value(payload.fetch("roommate_history"))
  end

  def end_date = @end_date
  def lowest(high: false) = high ? @lowest_high : @lowest
  def days_below(limit, high: false) = days.count { |day| (high ? day.balance_high : day.balance) < limit }
  def big_items(_min = 500) = @big_items
  def paycheck_late_risk = @paycheck_late_risk
  def roommate_history = @roommate_history
  def assumption_list = @assumptions

  private
    def build_event(value)
      data = deep_value(value)
      Event.new(**data)
    end

    def build_day(value)
      data = deep_value(value)
      data[:events] = Array(value["events"]).map { |event| build_event(event) }
      Day.new(**data)
    end

    def deep_value(value)
      case value
      when Hash
        value.to_h do |key, item|
          converted = if key.to_s.in?(%w[date today end_date last start finish rent_date window_from high_since]) && item.is_a?(String)
            Date.iso8601(item)
          else
            deep_value(item)
          end
          [ key.to_sym, converted ]
        end
      when Array
        value.map { |item| deep_value(item) }
      when String
        value.match?(/\A-?\d+(?:\.\d+)?\z/) ? decimal(value) : value
      else
        value
      end
    end

    def decimal(value)
      value.nil? ? nil : BigDecimal(value.to_s)
    end
end
