require "test_helper"

# Regression test for a real production incident: GoogleSheetsSyncJob.perform_later raised
# (SolidQueue::Job::EnqueueError, because the queue backend's own tables hadn't been migrated in production)
# straight out of ProduitDeal's after_commit callback, crashing every produit save with a 500 — which
# surfaced to the user as the whole inline-edit table vanishing, since Turbo had no frame content to fall
# back on for the error response. GoogleSheetsSyncJob.enqueue must swallow any enqueue failure so this
# background side effect can never again take down the primary save it's attached to.
class GoogleSheetsSyncJobTest < ActiveSupport::TestCase
  test "enqueue rescues any error from perform_later instead of letting it propagate" do
    GoogleSheetsSyncJob.define_singleton_method(:perform_later) { raise "queue backend unavailable" }

    assert_nothing_raised { GoogleSheetsSyncJob.enqueue }
  ensure
    GoogleSheetsSyncJob.singleton_class.send(:remove_method, :perform_later)
  end

  test "enqueue still enqueues normally when the queue backend is healthy" do
    assert_enqueued_with(job: GoogleSheetsSyncJob) { GoogleSheetsSyncJob.enqueue }
  end
end
