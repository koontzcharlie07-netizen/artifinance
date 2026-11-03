module EmailVerification
  module_function

  def required?
    ArtifinanceCore.call("access_email_verification_required", {}, timeout: 3).fetch("required")
  end
end
