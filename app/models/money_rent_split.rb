# Rent at your share everywhere in Sure. Each rent payment from checking that has a roommate's Venmo within
# 3 days before (or 1 after) is split, with Sure's own transaction split, into:
#   - "your share"       rent minus the roommate's part, category Mortgage / Rent (counts as spending)
#   - "roommate's share" the roommate's part, recorded as a transfer (funds_movement), so it isn't spending
# and the Venmo itself is recorded as a transfer too, so it isn't income. Sure's dashboard, cash flow (Sankey),
# budgets and category totals all leave transfers out, so they show rent at your share and no Venmo income.
# Balances don't change: Sure computes them from the split parts, which add up to the payment.
#
# The roommate's part is the Venmo rounded down to $100 ($2,600 for Venmos of $2,600-$2,692): the rest of a
# Venmo above that is usually a split bill, and stays out of income with it.
# Runs after every family sync (Family::Syncer) and from `money rent`; already-split payments are left alone.
class MoneyRentSplit
  KEY = "money_app_rent".freeze
  RENT_CATEGORY = "Mortgage / Rent".freeze

  attr_reader :family, :stats

  def initialize(family)
    @family = family
    @stats = { split: 0, already: 0, no_venmo: 0 }
  end

  def apply!
    category = family.categories.find_by(name: RENT_CATEGORY)
    return stats unless category

    used = Transaction.where("extra -> '#{KEY}' ->> 'role' = 'roommate_share'")
                      .pluck(Arel.sql("extra -> '#{KEY}' ->> 'venmo_entry_id'")).compact.to_set
    rent_payments(category).each do |rent|
      if rent.child_entries.exists?
        stats[:already] += 1
        next
      end
      venmo = roommate_venmo(rent, used)
      unless venmo
        stats[:no_venmo] += 1
        next
      end
      portion = (venmo.amount.abs / 100).floor * 100
      next unless portion.positive? && portion < rent.amount

      split(rent, venmo, portion, category)
      used << venmo.id
      stats[:split] += 1
    end
    stats
  end

  # What was split, by month: [{month:, date:, rent:, roommate_part:, your_share:, venmo:}]
  def self.history(family)
    Entry.joins(:account).where(accounts: { family_id: family.id })
         .joins("JOIN transactions t ON t.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
         .where("t.extra -> '#{KEY}' ->> 'role' = 'roommate_share'")
         .order(:date).map do |part|
      { date: part.date, roommate_part: part.amount, rent: part.parent_entry&.amount, name: part.parent_entry&.name,
        venmo_entry_id: part.entryable.extra.dig(KEY, "venmo_entry_id") }
    end
  end

  private
    def checking_ids
      @checking_ids ||= family.accounts.where(status: "active", accountable_type: "Depository").pluck(:id)
    end

    def rent_payments(category)
      Entry.where(account_id: checking_ids, entryable_type: "Transaction", parent_entry_id: nil)
           .joins("JOIN transactions t ON t.id = entries.entryable_id")
           .where("t.category_id = ? AND entries.amount >= 1000", category.id)
           .order(:date)
    end

    def roommate_venmo(rent, used)
      candidates = Entry.where(account_id: checking_ids, entryable_type: "Transaction", parent_entry_id: nil, excluded: false)
                        .where(date: (rent.date - 3)..(rent.date + 1))
                        .where("entries.amount BETWEEN ? AND ?", -rent.amount * 0.65, -rent.amount * 0.35)
                        .includes(:entryable).to_a
      candidates.reject! do |e|
        t = e.entryable
        used.include?(e.id) || t.transfer.present? || t.kind == "cc_payment" || t.category&.name == "Income"
      end
      candidates.min_by { |e| [ (e.date - rent.date).abs, e.id ] }
    end

    def split(rent, venmo, portion, category)
      base = rent.name.to_s.split(/\s*\*{2,}/).first.presence || rent.name
      Entry.transaction do
        yours, roommates = rent.split!([
          { name: "#{base} (your share)", amount: rent.amount - portion, category_id: category.id },
          { name: "#{base} (roommate's share, repaid by Venmo #{venmo.date.strftime('%b %-d')})", amount: portion, category_id: nil }
        ])
        yours.entryable.update!(extra: (yours.entryable.extra || {}).merge(KEY => { "role" => "your_share" }))
        roommates.entryable.update!(kind: "funds_movement",
                                    extra: (roommates.entryable.extra || {}).merge(KEY => { "role" => "roommate_share", "venmo_entry_id" => venmo.id }))
        txn = venmo.entryable
        txn.update!(kind: "funds_movement", category_id: nil,
                    extra: (txn.extra || {}).merge(KEY => { "role" => "roommate_venmo", "rent_entry_id" => rent.id }))
        venmo.mark_user_modified! if venmo.respond_to?(:mark_user_modified!)
      end
    end
end
