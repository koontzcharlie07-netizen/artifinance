# Makes the one Sure login on the first start; prints the Plaid item IDs Sure already has.
# stdin: {"email": ..., "password": ...}. Never prints the password.
input = JSON.parse($stdin.read)
created = false

unless User.exists?
  ActiveRecord::Base.transaction do
    family = Family.create!(name: "Koontz", currency: "USD", country: "US", locale: "en",
                            date_format: "%m-%d-%Y", timezone: "America/New_York")
    User.create!(family: family, email: input.fetch("email"), password: input.fetch("password"),
                 first_name: "Charles", last_name: "Koontz", role: :super_admin,
                 onboarded_at: Time.current, set_onboarding_preferences_at: Time.current,
                 set_onboarding_goals_at: Time.current, show_ai_sidebar: false)
    family.categories.bootstrap!
  end
  created = true
end

# Nobody else can sign up, even from this Mac.
Setting.onboarding_state = "closed"

puts({ created: created, plaid_ids: PlaidItem.pluck(:plaid_id) }.to_json)
