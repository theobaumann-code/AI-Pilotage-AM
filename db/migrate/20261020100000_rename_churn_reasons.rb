class RenameChurnReasons < ActiveRecord::Migration[8.1]
  # The list of churn reasons changed (see ProduitDeal::CHURN_REASONS). Reasons already entered are carried
  # over to their closest new equivalent; one with no counterpart goes back to "À qualifier" (blank) rather
  # than being forced onto a wrong reason — its comment is untouched.
  MAPPING = {
    "Offre concurrente" => "Meilleure offre concurrente",
    "Insatisfaction (service, gestion)" => "Qualité de la gestion",
    "Cessation d'activité / fusion" => "Rachat/Fusion"
  }.freeze

  NEW_REASONS = ["Meilleure offre concurrente", "Qualité de la gestion", "Non conformité", "Conseil apporté",
                 "Expérience client", "Rachat/Fusion", "Autre"].freeze

  def up
    MAPPING.each do |old_reason, new_reason|
      execute "UPDATE deals SET churn_reason = #{quote(new_reason)} WHERE type = 'ProduitDeal' AND churn_reason = #{quote(old_reason)}"
    end
    execute <<~SQL
      UPDATE deals SET churn_reason = NULL
      WHERE type = 'ProduitDeal' AND churn_reason IS NOT NULL
        AND churn_reason NOT IN (#{NEW_REASONS.map { |reason| quote(reason) }.join(", ")})
    SQL
  end

  def down
    # The previous reasons can't be recovered from the new ones.
  end
end
