class AddUserToDeals < ActiveRecord::Migration[8.1]
  def change
    # Optional owner override, used only by UpsellDeal: nil means "follows the company's AM" (the default,
    # and the only state a ProduitDeal is ever in — produits always move as a whole with their company).
    # A non-nil value lets a single upsell be reassigned to a different AM without moving the company or
    # its produits.
    add_reference :deals, :user, null: true, foreign_key: true
  end
end
