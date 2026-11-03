class MoneyRentSplit
  attr_reader :family

  def initialize(family)
    @family = family
  end

  def apply!
    ArtifinanceCore.call("rent_split", { family_id: family.id }, timeout: 30).deep_symbolize_keys
  end

  def self.history(family)
    ArtifinanceCore.call("rent_split_history", { family_id: family.id }, timeout: 10).map(&:deep_symbolize_keys)
  end
end
