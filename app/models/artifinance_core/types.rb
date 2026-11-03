module ArtifinanceCore::Types
  module_function

  def load(value)
    case value
    when Hash
      value.to_h do |key, item|
        parsed_key = key.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/) ? Date.iso8601(key) : key.to_sym
        [ parsed_key, load(item) ]
      end
    when Array
      value.map { |item| load(item) }
    when String
      if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value)
      elsif value.match?(/\A\d{4}-\d{2}-\d{2}T/)
        Time.zone.parse(value)
      elsif value.match?(/\A-?\d+(?:\.\d+)?\z/)
        BigDecimal(value)
      else
        value
      end
    else
      value
    end
  end
end
