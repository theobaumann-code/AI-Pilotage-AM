require "test_helper"

class TrashBatchTest < ActiveSupport::TestCase
  test "a trashed archive entry is invisible by default, and restore! brings it back" do
    entry = ArchiveEntry.create!(
      year: 2025, am_name: "AM Un", company_name: "Entreprise X",
      deal_type: "ProduitDeal", produit: "Mutuelle", statut_renouvellement: "En cours"
    )
    batch = TrashBatch.create!(year: 2025, deleted_at: Time.current)
    entry.update!(trash_batch: batch)

    # Default scope hides trashed entries everywhere — this is the structural guarantee that a deleted
    # year "ne s'archive plus" silently anywhere until explicitly restored.
    assert_not ArchiveEntry.exists?(entry.id), "trashed entries must not appear in the default (visible) scope"
    assert ArchiveEntry.trashed.exists?(entry.id)

    batch.restore!

    assert ArchiveEntry.exists?(entry.id), "restore! must bring the entry back into the visible/default scope"
    assert_nil ArchiveEntry.find(entry.id).trash_batch_id
    assert_not TrashBatch.exists?(batch.id), "restore! consumes the batch record itself"
  end
end
