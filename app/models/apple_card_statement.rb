# An Apple Card statement exported from Wallet (Export Transactions: CSV or OFX), imported into the
# family's "Apple Card" credit card account. Same parsing and transaction IDs as ~/banking-app's importer:
# date + amount + description, plus how many identical rows came before it in the same file, so
# re-importing a statement (or an overlapping one) adds nothing twice.
#
# Apple's CSV already uses this app's signs (purchases positive, payments and refunds negative).
# OFX is the other way round, so its amounts are flipped.
require "csv"

class AppleCardStatement
  class Invalid < StandardError; end

  SOURCE = "apple_card_statement".freeze
  # The account and source ~/banking-app's mirror (operations/apple_card.rb) writes; reused so its rows
  # and a dropped file's rows dedupe against each other.
  MIRROR_SOURCE = "banking_app_apple_card".freeze
  INSTITUTION = "Apple Card (statement import)".freeze
  CSV_COLUMNS = [ "Transaction Date", "Description", "Merchant", "Category", "Type", "Amount (USD)" ].freeze

  # Apple's categories, as the default category they belong to (Category.bootstrap! names).
  CATEGORY_KEYS = {
    "Restaurants" => "food_and_drink", "Alcohol" => "food_and_drink", "Grocery" => "groceries",
    "Transportation" => "transportation", "Gas" => "transportation",
    "Airlines" => "travel", "Hotels" => "travel", "Travel" => "travel",
    "Shopping" => "shopping", "Installment" => "shopping", "Entertainment" => "entertainment",
    "Medical" => "healthcare", "Health" => "healthcare", "Insurance" => "insurance",
    "Utilities" => "utilities", "Services" => "services"
  }.freeze

  Row = Struct.new(:id, :date, :description, :merchant, :apple_category, :type, :amount, keyword_init: true)

  attr_reader :filename, :rows, :balance, :as_of, :file_format

  def initialize(filename:, content:)
    @filename = filename.to_s
    text = content.to_s.dup.force_encoding("UTF-8").scrub.delete_prefix("﻿")
    if ofx?(text)
      @file_format = "OFX"
      parse_ofx(text)
    else
      @file_format = "CSV"
      parse_csv(text)
    end
    raise Invalid, "no transactions in this file" if @rows.empty?
    assign_ids
  end

  # Imports into the family's Apple Card account (created on first use). Returns what happened.
  def import_into(family, owner:)
    Category.transaction { family.categories.bootstrap! } if family.categories.none?
    account, source = apple_card_account(family, owner)
    categories = family.categories.index_by(&:name)
    history = merchant_categories(categories)
    added = 0

    ActiveRecord::Base.transaction do
      rows.each do |row|
        entry = account.entries.find_or_initialize_by(external_id: row.id, source: source)
        next unless entry.new_record?

        merchant = row.merchant.present? ? FamilyMerchant.find_or_create_by!(family: family, name: row.merchant) : nil
        entry.assign_attributes(date: row.date, name: row.description, amount: row.amount, currency: "USD")
        entry.entryable = Transaction.new(
          kind: kind_for(row),
          merchant: merchant,
          category: category_for(row, categories, history)
        )
        entry.save!
        added += 1
      end
    end

    anchor_balance(account) unless source == MIRROR_SOURCE
    family.auto_match_transfers!(account: account) if added.positive?
    account.sync_later

    { file: filename, label: label, format: file_format, rows: rows.size, added: added,
      duplicates: rows.size - added, account_id: account.id }
  end

  def label
    months = rows.map { |r| r.date.beginning_of_month }.tally
    main = months.select { |_, n| n >= 0.1 * rows.size }.keys.sort.presence || months.keys.sort
    first, last = main.first, main.last
    if first == last
      first.strftime("%B %Y")
    elsif first.year == last.year
      "#{first.strftime('%B')} – #{last.strftime('%B %Y')}"
    else
      "#{first.strftime('%B %Y')} – #{last.strftime('%B %Y')}"
    end
  end

  private
    def ofx?(text)
      filename.downcase.end_with?(".ofx", ".qfx", ".qbo") || text.lstrip.upcase.start_with?("OFXHEADER", "<?XML", "<OFX")
    end

    def parse_csv(text)
      table = CSV.parse(text, headers: true)
      unless (CSV_COLUMNS - table.headers.compact.map(&:strip)).empty?
        raise Invalid, "not an Apple Card statement: the columns aren't Apple's (#{CSV_COLUMNS.join(', ')})"
      end

      @rows = table.filter_map do |r|
        next if r["Transaction Date"].to_s.strip.empty?
        Row.new(date: parse_date(r["Transaction Date"]), description: r["Description"].to_s.split.join(" "),
                merchant: r["Merchant"].to_s.strip, apple_category: r["Category"].to_s.strip,
                type: r["Type"].to_s.strip, amount: money(r["Amount (USD)"]))
      end
    rescue CSV::MalformedCSVError
      raise Invalid, "not an Apple Card statement: unreadable CSV"
    end

    def parse_ofx(text)
      blocks = text.scan(%r{<STMTTRN>(.*?)(?=</STMTTRN>|<STMTTRN>|</BANKTRANLIST>)}mi).flatten
      raise Invalid, "not an Apple Card statement: not an OFX file" if blocks.empty? && !text.upcase.include?("<OFX>")

      @rows = blocks.map do |block|
        name = ofx_tag(block, "NAME").split.join(" ").presence || ofx_tag(block, "MEMO")
        kind = ofx_tag(block, "TRNTYPE").upcase
        amount = -money(ofx_tag(block, "TRNAMT"))
        type =
          if name.upcase.include?("DAILY CASH") then "Debit"
          elsif amount.negative? && (%w[PAYMENT DIRECTDEP XFER].include?(kind) || name.upcase.match?(/PAYMENT|ACH DEPOSIT/)) then "Payment"
          elsif amount.negative? then "Credit"
          else "Purchase"
          end
        Row.new(date: parse_date(ofx_tag(block, "DTPOSTED")[0, 8]), description: name, merchant: name.titleize,
                apple_category: "", type: type, amount: amount)
      end

      ledger = text[%r{<LEDGERBAL>(.*?)(?:</LEDGERBAL>|<AVAILBAL>|\z)}mi, 1]
      if ledger && ofx_tag(ledger, "BALAMT").present?
        @balance = -money(ofx_tag(ledger, "BALAMT"))
        when_ = ofx_tag(ledger, "DTASOF")
        @as_of = parse_date(when_[0, 8]) if when_.length >= 8
      end
    end

    def ofx_tag(block, tag)
      block[/<#{tag}>([^<\r\n]*)/i, 1].to_s.strip
    end

    def money(text)
      BigDecimal(text.to_s.gsub(/[,$\s]/, "")).round(2)
    rescue ArgumentError
      raise Invalid, "unreadable amount #{text.inspect}"
    end

    def parse_date(text)
      text = text.to_s.strip
      [ "%m/%d/%Y", "%Y-%m-%d", "%m/%d/%y", "%Y%m%d" ].each do |fmt|
        return Date.strptime(text, fmt)
      rescue Date::Error
        next
      end
      raise Invalid, "unreadable date #{text.inspect}"
    end

    def assign_ids
      seen = Hash.new(0)
      rows.each do |r|
        base = format("%s|%.2f|%s", r.date.iso8601, r.amount, r.description.upcase)
        seen[base] += 1
        r.id = "apple-" + Digest::SHA1.hexdigest("#{base}|#{seen[base]}")[0, 24]
      end
    end

    def apple_card_account(family, owner)
      mirrored = Account.find_by(id: Setting["money_app_apple_card_account_id"], family_id: family.id)
      return [ mirrored, MIRROR_SOURCE ] if mirrored

      account = family.accounts.find_by(accountable_type: "CreditCard", institution_name: INSTITUTION)
      account ||= Account.create_and_sync(
        { family: family, owner: owner, name: "Apple Card", balance: 0, currency: "USD",
          accountable_type: "CreditCard", institution_name: INSTITUTION },
        skip_initial_sync: true
      )
      [ account, SOURCE ]
    end

    def kind_for(row)
      case row.type
      when "Payment" then "cc_payment"
      when "Debit" then "one_time" # Daily Cash adjustment: not spending
      else "standard"
      end
    end

    def category_for(row, categories, history)
      return nil if %w[Payment Debit].include?(row.type) || row.description.upcase.include?("DAILY CASH")
      return categories[default_name("fees")] if %w[Interest Fee].include?(row.type)

      key = CATEGORY_KEYS[row.apple_category]
      return categories[default_name(key)] if key
      # A refund (or an OFX row) has no category of its own: use what that merchant's purchases had.
      history[row.merchant.downcase]
    end

    def merchant_categories(categories)
      rows.select { |r| r.amount.positive? && CATEGORY_KEYS[r.apple_category] }
          .to_h { |r| [ r.merchant.downcase, categories[default_name(CATEGORY_KEYS[r.apple_category])] ] }
    end

    def default_name(key)
      I18n.t("models.category.defaults.#{key}")
    end

    # What's owed comes only from an OFX statement (Wallet's CSV has none). The newest statement balance wins;
    # until there is one the card counts as $0, so a payment without the earlier spending doesn't show up as
    # money owed to you. The opening balance is set so the card ends at that amount.
    def anchor_balance(account)
      key = "apple_card_statement_balance:#{account.id}"
      known_as_of, known_balance = Setting[key].to_s.split("|")
      if balance && (as_of || rows.map(&:date).max).iso8601 >= known_as_of.to_s
        known_as_of, known_balance = (as_of || rows.map(&:date).max).iso8601, balance.to_s
        Setting[key] = "#{known_as_of}|#{known_balance}"
      end

      txns = account.entries.where(entryable_type: "Transaction")
      oldest = txns.minimum(:date) or return
      opening =
        if known_balance
          BigDecimal(known_balance) - txns.where("date <= ?", Date.parse(known_as_of)).sum(:amount)
        else
          -txns.sum(:amount)
        end
      Account::OpeningBalanceManager.new(account).set_opening_balance(balance: opening, date: oldest - 1)
    end
end
