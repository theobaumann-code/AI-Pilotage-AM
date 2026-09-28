class AppSetting < ApplicationRecord
  # Singleton row — the "année en cours" the whole app pivots around, matching state.anneeEnCours
  # in the original (a single global value, not per-AM).
  def self.instance
    first_or_create!(annee_en_cours: Date.current.year)
  end

  # No longer a stored column — "churn non accompagné" is tracked entreprise par entreprise (plus an
  # "Autre" catch-all for small accounts) in NonAccompagneChurnEntry instead of one lump figure admins
  # typed in directly. Kept as a method of the same name so PortfolioSummary#non_accompagne_churn and
  # every view that reads @app_setting.churn_non_accompagne don't need to know the source changed.
  def churn_non_accompagne
    NonAccompagneChurnEntry.sum(:amount)
  end
end
