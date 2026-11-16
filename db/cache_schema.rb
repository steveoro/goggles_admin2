# This file holds the Solid Cache schema (as shipped by the solid_cache gem) and is loaded
# into the local SQLite 'cache' DB by `bin/rails solid:prepare`.
#
# Keep 'schema_dump: false' on the 'cache:' entries of config/database.yml, or any
# db:migrate / db:schema:dump run will rewrite this file from the current DB contents.

ActiveRecord::Schema[8.1].define(version: 1) do
  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", limit: 1024, null: false
    t.binary "value", limit: 536870912, null: false
    t.datetime "created_at", null: false
    t.integer "key_hash", limit: 8, null: false
    t.integer "byte_size", limit: 4, null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end
end
