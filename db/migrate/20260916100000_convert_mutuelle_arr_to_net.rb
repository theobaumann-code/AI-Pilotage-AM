class ConvertMutuelleArrToNet < ActiveRecord::Migration[8.1]
  # Requested conversion factor: gross Mutuelle ARR → net. Applies to Mutuelle only — Prévoyance was
  # already quoted net, so it's untouched (both here and in Deal::UPSELL_RATE_PER_EMPLOYEE).
  GROSS_TO_NET = 1.1537
  # These three AMs' portfolios were already entered in net ARR — excluded so their already-correct
  # figures aren't divided a second time.
  ALREADY_NET_AM_NAMES = ["Emila", "Igor Piedelièvre", "Paul Basset"].freeze

  def up
    convert(1 / GROSS_TO_NET)
  end

  # Not bit-exact — arr is stored to 2 decimal places, so a value already rounded on the way in can't be
  # reconstructed past that precision on the way back out. Close enough for a rollback safety net, not
  # meant to be run in ordinary operation.
  def down
    convert(GROSS_TO_NET)
  end

  private

  def convert(factor)
    excluded_ids = excluded_am_ids
    excluded_clause = excluded_ids.any? ? "AND companies.user_id NOT IN (#{excluded_ids.join(", ")})" : ""

    execute <<~SQL
      UPDATE deals
      SET arr = ROUND((deals.arr * #{factor})::numeric, 2)
      FROM companies
      WHERE deals.company_id = companies.id
        AND deals.type = 'ProduitDeal'
        AND deals.produit = 'Mutuelle'
        #{excluded_clause}
    SQL
  end

  def excluded_am_ids
    names = ALREADY_NET_AM_NAMES.map { |name| connection.quote(name) }.join(", ")
    execute("SELECT id FROM users WHERE trim(name) IN (#{names})").map { |row| row["id"] }
  end
end
