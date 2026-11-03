class ForecastController < ApplicationController
  def show
    @private_page = ArtifinanceCore.call("forecast_page", { family_id: Current.family.id }, timeout: 20).fetch("html")
    @breadcrumbs = [ [ "Home", root_path ], [ "Forecast", nil ] ]
  end
end
