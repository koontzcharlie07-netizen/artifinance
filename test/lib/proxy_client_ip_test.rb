require "test_helper"
require Rails.root.join("lib/proxy_client_ip").to_s

class ProxyClientIpTest < ActiveSupport::TestCase
  setup do
    @seen = nil
    @app = ProxyClientIp.new(->(env) { @seen = env; [ 200, {}, [] ] }, secret: "s3cret")
  end

  test "trusts the proxy's client IP only when the origin secret matches" do
    call("HTTP_X_ORIGIN_SECRET" => "s3cret", "HTTP_X_REAL_IP" => "198.51.100.7",
         "HTTP_X_FORWARDED_FOR" => "198.51.100.7, 76.76.21.9", "HTTP_FLY_CLIENT_IP" => "76.76.21.9")

    assert_equal "198.51.100.7", request.ip
    assert_equal "198.51.100.7", request.remote_ip
    assert_nil @seen["HTTP_X_ORIGIN_SECRET"], "the secret must not reach the app"
  end

  test "ignores forged client-IP headers without the secret" do
    call("HTTP_X_ORIGIN_SECRET" => "guess", "HTTP_X_REAL_IP" => "1.2.3.4",
         "HTTP_X_FORWARDED_FOR" => "1.2.3.4", "HTTP_FLY_CLIENT_IP" => "203.0.113.50")

    assert_equal "203.0.113.50", request.ip
    assert_equal "203.0.113.50", request.remote_ip
  end

  test "falls back to X-Forwarded-For's first entry from the proxy" do
    call("HTTP_X_ORIGIN_SECRET" => "s3cret", "HTTP_X_FORWARDED_FOR" => "2001:db8::1, 76.76.21.9")

    assert_equal "2001:db8::1", request.ip
  end

  test "rejects junk addresses" do
    call("HTTP_X_ORIGIN_SECRET" => "s3cret", "HTTP_X_REAL_IP" => "not-an-ip", "HTTP_FLY_CLIENT_IP" => "203.0.113.9")

    assert_equal "203.0.113.9", request.ip
  end

  test "without a configured secret only Fly-Client-IP counts" do
    app = ProxyClientIp.new(->(env) { @seen = env; [ 200, {}, [] ] }, secret: nil)
    app.call(Rack::MockRequest.env_for("/", "REMOTE_ADDR" => "10.0.0.1", "HTTP_X_ORIGIN_SECRET" => "",
                                           "HTTP_X_REAL_IP" => "1.2.3.4", "HTTP_FLY_CLIENT_IP" => "203.0.113.10"))

    assert_equal "203.0.113.10", request.ip
  end

  private
    def call(headers)
      @app.call(Rack::MockRequest.env_for("/", { "REMOTE_ADDR" => "172.16.0.2" }.merge(headers)))
    end

    def request
      ActionDispatch::Request.new(@seen)
    end
end
