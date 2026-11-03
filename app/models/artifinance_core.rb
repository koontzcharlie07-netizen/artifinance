module ArtifinanceCore
  class Error < StandardError; end
  class Unavailable < Error; end
  class RemoteError < Error
    attr_reader :remote_class, :details

    def initialize(message, remote_class: nil, details: nil)
      super(message)
      @remote_class = remote_class
      @details = details
    end
  end

  module_function

  def call(operation, payload = {}, timeout: 10)
    Client.call(operation, payload, timeout: timeout)
  end
end
