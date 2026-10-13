class ZeroProbabilityOfLostUpsells < ActiveRecord::Migration[8.1]
  # Upsells already marked "Perdu" kept the % de chance they had before the client decided, so they still
  # counted in every projection. UpsellDeal now forces 0 for a lost deal; this brings existing rows in line.
  def up
    execute <<~SQL
      UPDATE deals SET probabilite_signature = 0
      WHERE type = 'UpsellDeal' AND statut_signature = 'Perdu' AND probabilite_signature <> 0
    SQL
  end

  def down
    # The previous probabilities were never meaningful for a lost deal and can't be recovered.
  end
end
