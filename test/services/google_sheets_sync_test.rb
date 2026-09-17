require "test_helper"

class GoogleSheetsSyncTest < ActiveSupport::TestCase
  test "raises instead of calling out to Google when unconfigured" do
    sync = GoogleSheetsSync.new(credentials_json: nil, spreadsheet_id: nil)
    error = assert_raises(GoogleSheetsSync::SyncError) { sync.sync_produits! }
    assert_match(/non configurée/i, error.message)
  end

  test "raises the same way when only the spreadsheet id is missing" do
    sync = GoogleSheetsSync.new(credentials_json: "{}", spreadsheet_id: nil)
    assert_raises(GoogleSheetsSync::SyncError) { sync.sync_produits! }
  end
end
