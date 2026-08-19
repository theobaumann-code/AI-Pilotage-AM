class TrashBatch < ApplicationRecord
  belongs_to :deleted_by, class_name: "User", optional: true
  has_many :archive_entries, -> { unscope(where: :trash_batch_id) }, dependent: :nullify, inverse_of: :trash_batch

  # Restore = un-trash, nothing more — matches the original's trash.push(...)/archive.push(...t.entries)
  # exactly: entries go right back to being ordinary archive rows, no data duplication or recomputation.
  def restore!
    transaction do
      archive_entries.update_all(trash_batch_id: nil)
      destroy
    end
  end
end
