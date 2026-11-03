require "ostruct"

class ArtifinanceCore::RemotePlaidProvider
  METHODS = %i[
    validate_webhook! get_link_token exchange_public_token get_item remove_item
    get_item_accounts get_transactions refresh_transactions get_item_investments
    get_item_liabilities get_institution
  ].freeze

  def initialize(family_id:, region:, credential_source:)
    @family_id = family_id
    @region = region
    @credential_source = credential_source
  end

  METHODS.each do |method_name|
    define_method(method_name) do |*args, **kwargs|
      payload = ArtifinanceCore.call(
        "plaid_provider_call",
        {
          family_id: @family_id,
          region: @region,
          credential_source: @credential_source,
          method: method_name,
          arguments: args,
          keywords: kwargs
        },
        timeout: 60
      )
      remote_value(payload.fetch("result"))
    rescue ArtifinanceCore::RemoteError => error
      raise unless error.remote_class == "Plaid::ApiError"

      details = error.details || {}
      raise Plaid::ApiError.new(code: details.fetch("code"), response_body: details.fetch("response_body"))
    end
  end

  private
    def remote_value(value)
      parsed = ArtifinanceCore::Types.load(value)
      case parsed
      when Hash
        OpenStruct.new(parsed.to_h { |key, item| [ key, remote_value(item) ] })
      when Array
        parsed.map { |item| remote_value(item) }
      else
        parsed
      end
    end
end
