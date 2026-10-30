require "test_helper"
require Rails.root.join("lib/public_host").to_s

class PublicHostTest < ActiveSupport::TestCase
  test "requests arriving at the app host look like they hit the public https host" do
    seen = nil
    app = PublicHost.new(->(env) { seen = Rack::Request.new(env); [ 200, {}, [] ] }, host: "artifinance.vercel.app")

    app.call(Rack::MockRequest.env_for("http://artifinance.fly.dev/session", "HTTP_X_FORWARDED_PORT" => "80"))

    assert_equal "artifinance.vercel.app", seen.host
    assert_equal "https", seen.scheme
    assert_equal "https://artifinance.vercel.app", seen.base_url
  end
end
