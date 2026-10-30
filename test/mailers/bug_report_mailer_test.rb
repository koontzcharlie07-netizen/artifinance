require "test_helper"

class BugReportMailerTest < ActionMailer::TestCase
  test "report addresses the support inbox and includes context" do
    mail = BugReportMailer.with(
      reporter_id: users(:family_admin).id,
      what_happened: "A chart disappeared.",
      page_url: "https://artifinance.example/reports",
      browser: "Test Browser 1.0",
      reported_at: Time.zone.parse("2026-10-30 12:00:00"),
      screenshot: nil
    ).report

    assert_equal [ BugReportMailer::RECIPIENT ], mail.to
    assert_includes mail.subject, "Bug report"
    assert_includes mail.text_part.body.decoded, "A chart disappeared."
    assert_includes mail.text_part.body.decoded, "Test Browser 1.0"
    assert_empty mail.attachments
  end
end
