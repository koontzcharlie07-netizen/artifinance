module ArtifinancePresentation
  FALLBACK = {
    "product_name" => "Personal Finance",
    "operator_name" => "the operator",
    "contact_email" => "support@example.com",
    "asset_version" => "default"
  }.freeze

  module_function

  def configuration
    cached = @configuration
    return cached if cached && @configuration_expires_at > Process.clock_gettime(Process::CLOCK_MONOTONIC)

    @configuration = ArtifinanceCore.call("presentation", {}, timeout: 3)
    @configuration_expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
    @configuration
  rescue ArtifinanceCore::Error
    FALLBACK
  end

  def product_name
    configuration.fetch("product_name")
  end

  # The name without a round trip: the core process (which makes Plaid calls) has its constants loaded.
  def local_product_name
    defined?(ArtifinanceCore::Presentation) ? ArtifinanceCore::Presentation::PRODUCT_NAME : product_name
  end

  # Where this deployment's complete source code is published (AGPL-3.0 section 13).
  def source_url
    ENV.fetch("SOURCE_CODE_URL", "https://github.com/koontzcharlie07-netizen/artifinance")
  end

  def operator_name
    configuration.fetch("operator_name")
  end

  def contact_email
    configuration.fetch("contact_email")
  end

  def asset_version
    configuration.fetch("asset_version")
  end
end
