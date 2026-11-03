class VelocityController < ApplicationController
  def show
    @private_page = ArtifinanceCore.call("velocity_page", { family_id: Current.family.id }, timeout: 20).fetch("html")
    @breadcrumbs = [ [ "Home", root_path ], [ "Velocity", nil ] ]
  end
end
