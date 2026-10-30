class BugReportMailer < ApplicationMailer
  RECIPIENT = "charlie@artifactlabs.ai"

  def report
    @reporter_id = params[:reporter_id]
    @what_happened = params[:what_happened]
    @page_url = params[:page_url]
    @browser = params[:browser]
    @reported_at = params[:reported_at]

    if (screenshot = params[:screenshot]).present?
      attachments[screenshot[:filename]] = {
        mime_type: screenshot[:content_type],
        content: screenshot[:content]
      }
    end

    mail to: RECIPIENT, subject: t("bug_report_mailer.report.subject", product_name: product_name)
  end
end
