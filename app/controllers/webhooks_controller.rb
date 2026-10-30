class WebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_authentication

  def plaid
    process_plaid_webhook(:us)
  end

  def plaid_eu
    process_plaid_webhook(:eu)
  end

  def stripe
    stripe_provider = Provider::Registry.get_provider(:stripe)

    begin
      webhook_body = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]

      stripe_provider.process_webhook_later(webhook_body, sig_header)

      head :ok
    rescue JSON::ParserError => error
      Sentry.capture_exception(error)
      Rails.logger.error "JSON parser error: #{error.message}"
      head :bad_request
    rescue Stripe::SignatureVerificationError => error
      Sentry.capture_exception(error)
      Rails.logger.error "Stripe signature verification error: #{error.message}"
      head :bad_request
    end
  end

  private
    def process_plaid_webhook(region)
      webhook_body = request.body.read
      plaid_verification_header = request.headers["Plaid-Verification"]

      client = plaid_webhook_client(region, webhook_body)
      raise "Plaid is not configured" unless client

      client.validate_webhook!(plaid_verification_header, webhook_body)

      PlaidItem::WebhookProcessor.new(webhook_body).process

      render json: { received: true }, status: :ok
    rescue => error
      Sentry.capture_exception(error)
      Rails.logger.error("Webhook error: #{error.class} - #{error.message}")
      render json: { error: "Invalid webhook" }, status: :bad_request
    end

    # Each family may have its own Plaid keys, so verify with the client that
    # linked the item. The item id is read before verification only to pick that
    # client; the signature check below still covers the whole body.
    def plaid_webhook_client(region, webhook_body)
      item_id = JSON.parse(webhook_body)["item_id"]
      plaid_item = PlaidItem.find_by(plaid_id: item_id) if item_id.present?

      if plaid_item
        plaid_item.family.plaid_provider_for(region, credential_source: plaid_item.credential_source)
      else
        Provider::Registry.plaid_provider_for_region(region)
      end
    end
end
