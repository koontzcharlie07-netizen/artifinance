class HostedUsage
  Trial = Data.define(
    :family_id, :family_name, :recorded_at, :trial_ends_at, :status,
    :member_count, :retained_sessions_count, :sessions_created_in_window_count,
    :latest_session_created_at, :cleanup_eligible, :synthetic_demo
  )
  CleanupCandidate = Data.define(
    :family_id, :family_name, :status, :trial_ends_at, :reason, :synthetic_demo
  )

  class << self
    def available?(request_host:)
      ArtifinanceCore.call("hosted_usage_available", { request_host: request_host }, timeout: 3).fetch("available")
    end
  end

  attr_reader :as_of, :window_start, :expiring_window_end, :summary, :trials,
    :cleanup_candidates, :supporter_status_counts

  def initialize
    data = ArtifinanceCore::Types.load(ArtifinanceCore.call("hosted_usage", {}, timeout: 15))
    @as_of = data.fetch(:as_of)
    @window_start = data.fetch(:window_start)
    @expiring_window_end = data.fetch(:expiring_window_end)
    @row_limit = data.fetch(:row_limit).to_i
    @cleanup_enabled = data.fetch(:cleanup_enabled)
    @summary = data.fetch(:summary)
    @trials = data.fetch(:trials).map { |row| Trial.new(**row) }
    @cleanup_candidates = data.fetch(:cleanup_candidates).map { |row| CleanupCandidate.new(**row) }
    @supporter_status_counts = data.fetch(:supporter_status_counts).transform_keys(&:to_s)
  end

  def row_limit = @row_limit
  def cleanup_enabled? = @cleanup_enabled
end
