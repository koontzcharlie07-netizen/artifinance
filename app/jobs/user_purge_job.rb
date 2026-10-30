class UserPurgeJob < ApplicationJob
  queue_as :low_priority

  # Plaid outages shouldn't leave bank connections live at Plaid after the
  # data is gone, so retry before giving up (the user is already signed out
  # and deactivated at this point).
  retry_on Plaid::ApiError, Faraday::Error, wait: :polynomially_longer, attempts: 8

  def perform(user)
    user.purge
  end
end
