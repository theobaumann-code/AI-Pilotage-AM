class AppSetting < ApplicationRecord
  # Singleton row — the "année en cours" the whole app pivots around, matching state.anneeEnCours
  # in the original (a single global value, not per-AM).
  def self.instance
    first_or_create!(annee_en_cours: Date.current.year)
  end
end
