# frozen_string_literal: true

require "ipaddr"

# Sets REMOTE_ADDR to the real visitor's IP so request.ip (rate limits, logs,
# sessions) isn't the proxy's address.
#
# Public traffic arrives Vercel -> Fly. Fly sets Fly-Client-IP to whoever
# connected to it, which is a shared Vercel edge address for proxied requests.
# Vercel puts the visitor's IP in X-Real-IP / X-Forwarded-For, but anyone who
# hits the Fly host directly could forge those. So the Vercel proxy also sends
# X-Origin-Secret (deploy/vercel-proxy/vercel.json, ORIGIN_SECRET), and those
# headers are trusted only when it matches. Otherwise Fly-Client-IP is used.
class ProxyClientIp
  SECRET_HEADER = "HTTP_X_ORIGIN_SECRET"

  def initialize(app, secret: ENV["ORIGIN_SECRET"])
    @app = app
    @secret = secret.to_s
  end

  def call(env)
    from_proxy = @secret.present? && ActiveSupport::SecurityUtils.secure_compare(env[SECRET_HEADER].to_s, @secret)
    env.delete(SECRET_HEADER)
    env["artifinance.via_proxy"] = from_proxy

    client_ip = (proxied_client_ip(env) if from_proxy) || valid_ip(env["HTTP_FLY_CLIENT_IP"])

    if client_ip
      env["REMOTE_ADDR"] = client_ip
      # Nothing downstream should re-derive the IP from forgeable headers.
      env["HTTP_X_FORWARDED_FOR"] = client_ip
      env.delete("HTTP_CLIENT_IP")
    end

    @app.call(env)
  end

  private
    def proxied_client_ip(env)
      valid_ip(env["HTTP_X_REAL_IP"]) ||
        valid_ip(env["HTTP_X_VERCEL_FORWARDED_FOR"].to_s.split(",").first) ||
        valid_ip(env["HTTP_X_FORWARDED_FOR"].to_s.split(",").first)
    end

    def valid_ip(value)
      candidate = value.to_s.strip
      return nil if candidate.empty?

      IPAddr.new(candidate).to_s
    rescue IPAddr::Error
      nil
    end
end
