class BugReport
  include ActiveModel::Model

  MAX_SCREENSHOT_SIZE = 5.megabytes
  SCREENSHOT_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze

  attr_accessor :what_happened, :page_url, :screenshot

  validates :what_happened, presence: true, length: { maximum: 4_000 }
  validate :screenshot_is_supported

  def screenshot_attachment
    return unless screenshot.present?

    screenshot.rewind
    {
      filename: File.basename(screenshot.original_filename.presence || "screenshot"),
      content_type: screenshot.content_type,
      content: screenshot.read
    }
  end

  private
    def screenshot_is_supported
      return unless screenshot.present?

      unless SCREENSHOT_CONTENT_TYPES.include?(screenshot.content_type)
        errors.add(:screenshot, :unsupported_type)
      end

      if screenshot.size > MAX_SCREENSHOT_SIZE
        errors.add(:screenshot, :too_large, size: ActiveSupport::NumberHelper.number_to_human_size(MAX_SCREENSHOT_SIZE))
      end
    end
end
