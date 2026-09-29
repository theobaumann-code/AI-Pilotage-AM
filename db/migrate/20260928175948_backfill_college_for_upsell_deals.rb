class BackfillCollegeForUpsellDeals < ActiveRecord::Migration[8.1]
  # UpsellDeal now requires college (see UpsellDeal#college validation) — every upsell created before this
  # gets the same default the new-upsell form itself uses, "Ensemble du personnel" (ProduitDeal::COLLEGES
  # first entry), so existing rows stay valid without anyone having to hand-edit them one by one.
  def up
    execute "UPDATE deals SET college = 'Ensemble du personnel' WHERE type = 'UpsellDeal' AND college IS NULL"
  end

  def down
    execute "UPDATE deals SET college = NULL WHERE type = 'UpsellDeal'"
  end
end
