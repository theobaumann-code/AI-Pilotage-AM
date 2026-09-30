class UpsellDeal < Deal
  PRODUITS = (ProduitDeal::PRODUITS + ["Mutuelle/Prévoyance"]).freeze
  STATUTS_SIGNATURE = ["Non démarré", "En cours", "Signé", "Perdu"].freeze
  SIGNE = "Signé"

  # Generic per-employee reference formula — communicated directly by Sarra Bachar on 2026-09-30, replacing
  # the Bonus Tracker BO estimate for upsells: Bonus Tracker's per-company invoice-based estimate turned out
  # to swing on how much of a company's headcount happened to have matured, invoiced sub-contracts (e.g.
  # ~78% covered for one client vs ~8% for another), which could make a smaller company outrank a much
  # larger one on ARR for the same product — a real inconsistency, not a data-sync issue. This flat, uniform
  # formula trades that invoice-level precision for a result that's always monotonic in headcount and fully
  # reproducible from data Pilotage NRR actually has (nombre_salaries, produit).
  #
  # Corrected the same day: the mutuelle base rate is tax-adjusted (divided by 1+taxe) and both rates are
  # weighted by their average affiliation rate (taux d'affiliation moyen — not every signed employee
  # actually enrolls), and the result IS the final per-employee ARR — no separate commission conversion on
  # top this time (unlike the first version of this formula).
  MUTUELLE_RATE_BASE = 140.0
  MUTUELLE_TAXE = 0.1532
  MUTUELLE_TAUX_AFFILIATION = 0.8
  PREVOYANCE_RATE_BASE = 36.0
  PREVOYANCE_TAUX_AFFILIATION = 0.95

  validates :produit, inclusion: { in: PRODUITS }
  validates :college, presence: true, inclusion: { in: ProduitDeal::COLLEGES }
  validates :statut_signature, inclusion: { in: STATUTS_SIGNATURE }
  validates :nombre_salaries, numericality: { greater_than_or_equal_to: 0 }
  validates :probabilite_signature, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }

  # An upsell's collège matters far less than a produit's (no per-collège contract to keep straight), so
  # unlike ProduitDeal, every UpsellDeal gets a sensible default instead of forcing every caller (forms,
  # CSV import, tests, the console) to always pass one explicitly. Only fills in when truly unset, so an
  # explicit value — including one already loaded from the database — is never overwritten.
  after_initialize { self.college ||= ProduitDeal::COLLEGES.first }

  before_validation :apply_business_rules
  before_validation :estimate_arr

  def signed?
    statut_signature == SIGNE
  end

  def arr_estimable?
    arr_estimation_source.present? && arr_estimation_source != "unavailable"
  end

  private

  # Pure arithmetic, so — unlike the old Bonus Tracker refresh, which only ran on specific field changes
  # to avoid pointless external calls — this simply recomputes on every save. arr can never drift out of
  # sync with produit/nombre_salaries, and every upsell always uses today's rates regardless of status
  # (Non démarré/En cours/Signé/Perdu all get a real, comparable ARR, not just active ones).
  def estimate_arr
    self.arr = (rate_per_employee * nombre_salaries.to_i).round(2)
    self.arr_estimation_source = "generique_par_salarie"
    self.arr_estimation_reference = "#{nombre_salaries.to_i} salarié(s) × #{rate_per_employee.round(2)} €/an (#{produit})"
    self.arr_estimation_formula_version = "generique-par-salarie-v2"
    self.arr_estimated_at = Time.current
  end

  def rate_per_employee
    case produit
    when "Mutuelle" then rate_per_employee_mutuelle
    when "Prévoyance" then rate_per_employee_prevoyance
    when "Mutuelle/Prévoyance" then rate_per_employee_mutuelle + rate_per_employee_prevoyance
    else 0.0
    end
  end

  def rate_per_employee_mutuelle
    (MUTUELLE_RATE_BASE / (1 + MUTUELLE_TAXE)) * MUTUELLE_TAUX_AFFILIATION
  end

  def rate_per_employee_prevoyance
    PREVOYANCE_RATE_BASE * PREVOYANCE_TAUX_AFFILIATION
  end

  # Rule 5: marking an upsell "Signé" always forces probabilite_signature to 100. Moving back off "Signé"
  # must not leave that forced 100 behind — it was never a real probability the AM entered, and leaving it
  # in place silently overstates the projected ARR (100% of the deal) until someone notices and fixes it
  # by hand. Only reset on an actual transition away from "Signé", so editing any other field on an
  # already-non-signed upsell doesn't touch it.
  def apply_business_rules
    if signed?
      self.probabilite_signature = 100
    elsif statut_signature_changed? && statut_signature_was == SIGNE
      self.probabilite_signature = 0
    end
  end
end
