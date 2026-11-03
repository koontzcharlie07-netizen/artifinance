class PrivateAssetsController < ApplicationController
  skip_authentication

  ALLOWED = %w[
    logomark.png android-chrome-192x192.png android-chrome-512x512.png
    apple-touch-icon.png favicon-16x16.png favicon-32x32.png favicon.ico
    logo-offline.png logo-pwa-maskable.png logo-pwa.png mstile-150x150.png
  ].freeze

  def show
    name = params[:name].to_s
    return head :not_found unless name.in?(ALLOWED)

    body, content_type = ArtifinanceCore::Client.asset(name)
    expires_in 1.hour, public: true
    send_data body, type: content_type, disposition: "inline"
  rescue ArtifinanceCore::Error
    head :service_unavailable
  end
end
