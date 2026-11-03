# frozen_string_literal: true

class ProxyClientIp
  SECRET_HEADER = "HTTP_X_ORIGIN_SECRET"

  def initialize(app, secret: nil)
    @app = app
  end

  def call(env)
    result = ArtifinanceCore.call(
      "access_resolve_client_ip",
      {
        origin_secret: env[SECRET_HEADER],
        real_ip: env["HTTP_X_REAL_IP"],
        vercel_forwarded_for: env["HTTP_X_VERCEL_FORWARDED_FOR"],
        forwarded_for: env["HTTP_X_FORWARDED_FOR"],
        fly_client_ip: env["HTTP_FLY_CLIENT_IP"]
      },
      timeout: 3
    )
    env.delete(SECRET_HEADER)
    env["artifinance.via_proxy"] = result.fetch("via_proxy")
    client_ip = result["client_ip"]

    if client_ip
      env["REMOTE_ADDR"] = client_ip
      # Nothing downstream should re-derive the IP from forgeable headers.
      env["HTTP_X_FORWARDED_FOR"] = client_ip
      env.delete("HTTP_CLIENT_IP")
    end

    @app.call(env)
  end
end
