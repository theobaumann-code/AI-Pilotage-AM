class Company < ApplicationRecord
  belongs_to :user

  has_many :deals, dependent: :destroy
  has_many :produit_deals, -> { where(type: "ProduitDeal") }, class_name: "ProduitDeal", inverse_of: :company
  has_many :upsell_deals, -> { where(type: "UpsellDeal") }, class_name: "UpsellDeal", inverse_of: :company

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  # The only way a company's AM ever changes — Deal never carries its own AM field, so this single
  # assignment is what "one company = one AM" means structurally (see original's reassignClientAM,
  # which had to manually walk every deal; here there's nothing else to update).
  def reassign_am!(new_user)
    update!(user: new_user)
  end
end
