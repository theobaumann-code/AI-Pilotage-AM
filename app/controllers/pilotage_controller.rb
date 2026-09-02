# "Résultats AM" — see ResultsPage for the shared roster/chart/upsells logic.
class PilotageController < ApplicationController
  include ResultsPage

  private

  def role_users
    User.active.ams.order(:name)
  end
end
