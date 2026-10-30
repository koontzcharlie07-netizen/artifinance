require "test_helper"

class AuthConfigPasswordResetTest < ActiveSupport::TestCase
  test "password reset is offered in production only when SMTP is configured" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))

    ClimateControl.modify(SMTP_ADDRESS: nil) { refute AuthConfig.password_reset_enabled? }
    ClimateControl.modify(SMTP_ADDRESS: "smtp.example.com") { assert AuthConfig.password_reset_enabled? }
  end
end
