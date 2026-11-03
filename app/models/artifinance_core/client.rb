require "net/http"
require "connection_pool"

class ArtifinanceCore::Client
  DEFAULT_URL = "http://core.process.artifinance-team.internal:3100"
  POOL_SIZE = 2

  class << self
    def call(operation, payload, timeout:)
      return in_process_call(operation, payload) if in_process?

      begin
        with_reconnect_retry { request(operation, payload, timeout: timeout) }
      rescue ArtifinanceCore::Error
        raise
      rescue StandardError => error
        raise ArtifinanceCore::Unavailable, "Artifinance Core is unavailable (#{error.class})"
      end
    end

    def asset(name, timeout: 5)
      uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "assets/#{ERB::Util.url_encode(name)}")
      request = Net::HTTP::Get.new(uri.request_uri)
      request["X-Artifinance-Core-Token"] = shared_secret
      response = with_reconnect_retry do
        with_connection(uri, timeout: timeout) { |http| http.request(request) }
      end
      raise ArtifinanceCore::RemoteError, "asset not found" unless response.is_a?(Net::HTTPSuccess)

      [ response.body, response["content-type"] || "application/octet-stream" ]
    rescue ArtifinanceCore::Error
      raise
    rescue StandardError => error
      raise ArtifinanceCore::Unavailable, "Artifinance Core is unavailable (#{error.class})"
    end

    def preconnect!
      Array.new(POOL_SIZE) do
        Thread.new { call("ping", {}, timeout: 2) }
      end.each(&:value)
      true
    end

    private
      def in_process?
        Rails.env.test? && ENV.fetch("ARTIFINANCE_CORE_IN_PROCESS", "true") == "true"
      end

      def in_process_call(operation, payload)
        require Rails.root.join("private/artifinance_core/dispatcher")
        ArtifinanceCore::Dispatcher.call(operation.to_s, payload.deep_stringify_keys)
      end

      def request(operation, payload, timeout:)
        uri = URI.join(base_url.end_with?("/") ? base_url : "#{base_url}/", "v1/#{operation}")
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["X-Artifinance-Core-Token"] = shared_secret
        request.body = JSON.generate(payload)

        response = with_connection(uri, timeout: timeout) { |http| http.request(request) }
        parsed = JSON.parse(response.body.presence || "{}")
        return parsed.fetch("data") if response.is_a?(Net::HTTPSuccess)

        raise ArtifinanceCore::RemoteError.new(
          parsed["error"] || "Artifinance Core returned HTTP #{response.code}",
          remote_class: parsed["class"],
          details: parsed["details"]
        )
      rescue EOFError, Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout
        raise
      end

      def with_reconnect_retry
        yield
      rescue EOFError, Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout
        # with_connection discards the failed pooled socket before re-raising,
        # so the single retry checks out a newly-created connection.
        yield
      end

      def with_connection(uri, timeout:)
        connection_pool(uri).with do |http|
          http.open_timeout = [ timeout, 2 ].min
          http.read_timeout = timeout
          yield http
        rescue EOFError, Errno::ECONNRESET, Net::ReadTimeout, Net::OpenTimeout
          connection_pool(uri).discard_current_connection do |broken|
            broken.finish if broken.started?
          rescue IOError
            nil
          end
          raise
        end
      end

      def connection_pool(uri)
        key = [ uri.host, uri.port, uri.scheme ]
        return @connection_pool if @connection_pool_key == key

        @connection_pool_mutex ||= Mutex.new
        @connection_pool_mutex.synchronize do
          next @connection_pool if @connection_pool_key == key

          @connection_pool&.shutdown { |http| http.finish if http.started? }
          @connection_pool_key = key
          @connection_pool = ConnectionPool.new(size: POOL_SIZE, timeout: 2) do
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = uri.scheme == "https"
            http.keep_alive_timeout = 120
            http.start
            http
          end
        end
      end

      def base_url
        ENV.fetch("ARTIFINANCE_CORE_URL", DEFAULT_URL)
      end

      def shared_secret
        ENV.fetch("ARTIFINANCE_CORE_SHARED_SECRET")
      end
  end
end
