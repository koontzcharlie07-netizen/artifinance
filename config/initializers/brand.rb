Rails.application.configure do
  config.x.product_name = "Personal Finance"
  config.x.brand_name = ""
end

unless ENV["ARTIFINANCE_CORE_PROCESS"] == "true"
  module ProductTranslationInterpolation
    def translate(locale, key, options = I18n::EMPTY_HASH)
      branding = ArtifinancePresentation.configuration
      result = super(locale, key, options)
      replace_private_brand_tokens(result, branding)
    end

    private
      def replace_private_brand_tokens(value, branding)
        case value
        when String
          value.gsub("PRIVATE_PRODUCT_NAME", branding.fetch("product_name"))
            .gsub("PRIVATE_OPERATOR_NAME", branding.fetch("operator_name"))
        when Array
          value.map { |item| replace_private_brand_tokens(item, branding) }
        when Hash
          value.transform_values { |item| replace_private_brand_tokens(item, branding) }
        else
          value
        end
      end
  end

  I18n::Backend::Simple.prepend(ProductTranslationInterpolation)
end
