# "Résultats KAM" — the same page as "Résultats AM" (see ResultsPage), scoped to KAM-role users instead.
# Viewing is restricted to KAM/admin: a plain AM's one difference in rights from a KAM is not seeing this.
class ResultatsKamController < ApplicationController
  before_action :require_kam_or_admin!

  include ResultsPage

  private

  def role_users
    User.active.kams.order(:name)
  end
end
