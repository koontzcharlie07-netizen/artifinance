# Forecast: checking balance day by day for about 90 days, from live data on every load (see MoneyForecast).
class ForecastController < ApplicationController
  def show
    @forecast = MoneyForecast.new(Current.family)
    @breadcrumbs = [ [ "Home", root_path ], [ "Forecast", nil ] ]
  end
end
