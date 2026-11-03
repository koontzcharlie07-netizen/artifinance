class ApplicationMailer < ActionMailer::Base
  default from: -> {
    email_address_with_name(ENV.fetch("EMAIL_SENDER", "sender@example.com"), ArtifinancePresentation.product_name)
  }
  layout "mailer"

  before_action :assign_branding

  helper_method :product_name, :brand_name

  private
    def assign_branding
      @product_name = product_name
      @brand_name = brand_name
    end

    def product_name
      ArtifinancePresentation.product_name
    end

    def brand_name
      ""
    end
end
