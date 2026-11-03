module SignupAllowlist
  module_function

  def enabled?
    ArtifinanceCore.call("access_allowlist", {}, timeout: 3).fetch("enabled")
  end

  def include?(email)
    ArtifinanceCore.call("access_allowlisted", { email: email }, timeout: 3).fetch("included")
  end
end
