module DailyWebUsageTracking
  extend ActiveSupport::Concern

  included do
    after_action :enqueue_daily_web_usage
  end

  private
    def enqueue_daily_web_usage
      payload = {
        user_id: Current.user&.id,
        request_method: request.request_method,
        response_status: response.status,
        response_media_type: response.media_type,
        controller_path: controller_path,
        xhr: request.xhr?,
        turbo_frame: turbo_frame_request?,
        purpose_headers: %w[Purpose Sec-Purpose X-Sec-Purpose].to_h { |header| [ header, request.headers[header] ] },
        remote_ip: request.remote_ip
      }
      ArtifinanceCore.call("daily_web_usage", payload, timeout: 3)
    rescue StandardError => error
      Rails.logger.debug("Daily web usage enqueue skipped: #{error.class}")
    end
end
