# A planned change on one BI account (kind + bi_id, like bi_accounts): "assign" it to a user or a recruit,
# put it back in the "reserve" to reassign, "drop" it (no longer followed by an AM) or "terminate" it (the client
# leaves: out of the study). original_am_email is the BO's AM when the change was made, to tell later whether the
# BO followed it or went another way.
class Projection::Move < ApplicationRecord
  ACTIONS = %w[assign reserve drop terminate].freeze

  belongs_to :user, optional: true
  belongs_to :recruit, class_name: "Projection::Recruit", optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :bi_id, uniqueness: { scope: :kind }
  validate :assign_has_one_target

  def key
    "#{kind}:#{bi_id}"
  end

  private

  def assign_has_one_target
    if action == "assign"
      errors.add(:base, "Un compte attribué doit avoir un destinataire") unless user_id.present? ^ recruit_id.present?
    elsif user_id.present? || recruit_id.present?
      errors.add(:base, "Seule une attribution a un destinataire")
    end
  end
end
