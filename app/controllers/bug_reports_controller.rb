class BugReportsController < ApplicationController
  def new
    @bug_report = BugReport.new(page_url: safe_page_url(params[:page_url]))
  end

  def create
    @bug_report = BugReport.new(bug_report_params)
    @bug_report.page_url = safe_page_url(@bug_report.page_url)

    if @bug_report.valid?
      BugReportMailer.with(
        reporter_id: Current.user.id,
        what_happened: @bug_report.what_happened,
        page_url: @bug_report.page_url,
        browser: request.user_agent.presence || t("bug_reports.unknown_browser"),
        reported_at: Time.current,
        screenshot: @bug_report.screenshot_attachment
      ).report.deliver_now

      redirect_to @bug_report.page_url, notice: t("bug_reports.create.thanks")
    else
      render :new, status: :unprocessable_entity
    end
  end

  private
    def bug_report_params
      params.require(:bug_report).permit(:what_happened, :page_url, :screenshot)
    end

    def safe_page_url(value)
      uri = URI.parse(value.to_s)
      return root_url unless uri.is_a?(URI::HTTP) && uri.origin == request.base_url

      uri.to_s
    rescue URI::InvalidURIError
      root_url
    end
end
