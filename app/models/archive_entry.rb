class ArchiveEntry < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :trash_batch, optional: true

  # A trashed year must never silently reappear anywhere (calculations, charts, filters) except via an
  # explicit restore — this default_scope is the structural guarantee of that constraint (the original's
  # "je ne veux pas que la corbeille n'archive quoi que ce soit").
  default_scope { where(trash_batch_id: nil) }
  scope :trashed, -> { unscope(where: :trash_batch_id).where.not(trash_batch_id: nil) }
end
