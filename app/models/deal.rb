class Deal < ApplicationRecord
  self.inheritance_column = :type

  belongs_to :company
  # Owner override — see the AddUserToDeals migration. Only ever set on UpsellDeal; a ProduitDeal's
  # effective_user is always its company's owner (produits move as a whole with the company, never alone).
  belongs_to :user, optional: true

  validates :produit, presence: true
  validates :arr, numericality: true
  validates :taux, numericality: true

  # Who this deal actually belongs to right now: the override if one was set (an upsell explicitly
  # reassigned to a different AM than its company), otherwise the company's own AM.
  def effective_user
    user || company.user
  end

  # For upsells, `arr` is the latest estimate returned by Bonus Tracker after
  # matching the company to the BO. It is deliberately not recomputed from a
  # fixed per-employee table here: doing so would silently replace the richer
  # premium/commission estimate whenever the record is displayed.
  def upsell_amount
    is_a?(UpsellDeal) ? arr.to_d : 0.to_d
  end

  def projection
    upsell_amount * (probabilite_signature.to_i / 100.0)
  end
end
