require "base64"

class BugReport
  include ActiveModel::Model

  attr_accessor :what_happened, :page_url, :screenshot

  def accepted_content_types
    metadata.fetch("accepted_content_types")
  end

  def submit(reporter_id:, browser:, remote_ip: nil)
    result = ArtifinanceCore.call(
      "bug_report_submit",
      {
        reporter_id: reporter_id,
        what_happened: what_happened,
        page_url: page_url,
        browser: browser,
        remote_ip: remote_ip,
        screenshot: encoded_screenshot
      },
      timeout: 30
    )
    result.fetch("errors", {}).each do |attribute, messages|
      Array(messages).each { |message| errors.add(attribute, message) }
    end
    result.fetch("submitted")
  end

  private
    def metadata
      @metadata ||= ArtifinanceCore.call("bug_report_metadata", {}, timeout: 3)
    end

    def encoded_screenshot
      return unless screenshot.present?

      screenshot.rewind
      {
        filename: File.basename(screenshot.original_filename.presence || "screenshot"),
        content_type: screenshot.content_type,
        content: Base64.strict_encode64(screenshot.read)
      }
    end
end
