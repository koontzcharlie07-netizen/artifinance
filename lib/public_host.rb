# frozen_string_literal: true

# Behind a proxy chain (Vercel rewrite -> Fly), the request that reaches Rails
# carries the Fly host. When APP_DOMAIN is set, treat every request as arriving
# at that public host over HTTPS, so redirects, cookies and the CSRF origin
# check all match the address people actually use. Requests sent straight to
# the Fly host still work for GETs, but forms posted from there fail the origin
# check, which keeps sign-in on the shared link.
class PublicHost
  def initialize(app, host:, https: true)
    @app = app
    @host = host
    @https = https
  end

  def call(env)
    env["HTTP_X_FORWARDED_HOST"] = @host
    if @https
      env["HTTP_X_FORWARDED_PROTO"] = "https"
      env["HTTP_X_FORWARDED_SSL"] = "on"
      env.delete("HTTP_X_FORWARDED_PORT")
    end
    @app.call(env)
  end
end
