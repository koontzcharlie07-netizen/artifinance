require "test_helper"

class BugReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    ActionMailer::Base.deliveries.clear
  end

  test "signed-in user can open the report form from the app navigation" do
    get root_url

    assert_response :success
    assert_select "a[aria-label='Report a bug']"

    get new_bug_report_url(page_url: transactions_url)

    assert_response :success
    assert_select "form[action='#{bug_report_path}']"
    assert_select "input[name='bug_report[page_url]'][value='#{transactions_url}']"
    assert_select "input[type='file'][name='bug_report[screenshot]']"
  end

  test "report emails the description screenshot and automatic context" do
    screenshot = uploaded_file(filename: "problem.png", content_type: "image/png", content: "fake-png")

    assert_emails 1 do
      post bug_report_url,
        params: {
          bug_report: {
            what_happened: "The balance card would not open.",
            page_url: transactions_url,
            screenshot: screenshot
          }
        },
        headers: { "User-Agent" => "Headless test browser" }
    end

    assert_redirected_to transactions_url
    assert_equal I18n.t("bug_reports.create.thanks"), flash[:notice]

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ BugReportMailer::RECIPIENT ], mail.to
    assert_includes mail.text_part.body.decoded, "The balance card would not open."
    assert_includes mail.text_part.body.decoded, transactions_url
    assert_includes mail.text_part.body.decoded, "Headless test browser"
    assert_includes mail.text_part.body.decoded, @user.id
    assert_equal [ "problem.png" ], mail.attachments.map(&:filename)
  end

  test "report requires a description and rejects non-image attachments" do
    attachment = uploaded_file(filename: "notes.txt", content_type: "text/plain", content: "not an image")

    assert_no_emails do
      post bug_report_url, params: {
        bug_report: { what_happened: "", page_url: root_url, screenshot: attachment }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role='alert']"
  end

  test "report ignores an off-site page URL" do
    assert_emails 1 do
      post bug_report_url, params: {
        bug_report: { what_happened: "Something went wrong.", page_url: "https://example.net/phishing" }
      }
    end

    assert_redirected_to root_url
    assert_includes ActionMailer::Base.deliveries.last.text_part.body.decoded, root_url
  end
end
