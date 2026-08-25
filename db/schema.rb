# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_25_141511) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "app_settings", force: :cascade do |t|
    t.integer "annee_en_cours", default: 2026, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "archive_entries", force: :cascade do |t|
    t.string "am_name", null: false
    t.decimal "arr", precision: 12, scale: 2, default: "0.0", null: false
    t.string "assureur"
    t.string "college"
    t.string "company_name", null: false
    t.datetime "created_at", null: false
    t.string "deal_type", null: false
    t.string "identifiant"
    t.integer "nombre_salaries", default: 0, null: false
    t.integer "probabilite_signature", default: 0, null: false
    t.string "produit", null: false
    t.string "statut_renouvellement"
    t.string "statut_signature"
    t.decimal "taux", precision: 6, scale: 2, default: "0.0", null: false
    t.bigint "trash_batch_id"
    t.datetime "updated_at", null: false
    t.decimal "upsell_amount", precision: 12, scale: 2, default: "0.0", null: false
    t.bigint "user_id"
    t.integer "year", null: false
    t.index ["trash_batch_id"], name: "index_archive_entries_on_trash_batch_id"
    t.index ["user_id"], name: "index_archive_entries_on_user_id"
    t.index ["year"], name: "index_archive_entries_on_year"
  end

  create_table "companies", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index "lower((name)::text)", name: "index_companies_on_lower_name", unique: true
    t.index ["user_id"], name: "index_companies_on_user_id"
  end

  create_table "deals", force: :cascade do |t|
    t.decimal "arr", precision: 12, scale: 2, default: "0.0", null: false
    t.string "assureur"
    t.string "college"
    t.bigint "company_id", null: false
    t.datetime "created_at", null: false
    t.string "identifiant"
    t.integer "nombre_salaries", default: 0, null: false
    t.integer "probabilite_signature", default: 0, null: false
    t.string "produit", null: false
    t.string "statut_renouvellement"
    t.string "statut_signature"
    t.decimal "taux", precision: 6, scale: 2, default: "0.0", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["company_id", "produit", "college", "assureur"], name: "index_deals_on_company_produit_college_assureur", unique: true, where: "((type)::text = 'ProduitDeal'::text)"
    t.index ["company_id"], name: "index_deals_on_company_id"
    t.index ["produit", "identifiant"], name: "index_deals_on_produit_and_identifiant_active", unique: true, where: "(((type)::text = 'ProduitDeal'::text) AND (identifiant IS NOT NULL))"
    t.index ["user_id"], name: "index_deals_on_user_id"
  end

  create_table "trash_batches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "deleted_at", null: false
    t.bigint "deleted_by_id"
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["deleted_by_id"], name: "index_trash_batches_on_deleted_by_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "name", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "archive_entries", "trash_batches"
  add_foreign_key "archive_entries", "users"
  add_foreign_key "companies", "users"
  add_foreign_key "deals", "companies"
  add_foreign_key "deals", "users"
  add_foreign_key "trash_batches", "users", column: "deleted_by_id"
end
