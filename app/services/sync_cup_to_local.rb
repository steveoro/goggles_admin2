# frozen_string_literal: true

# = SyncCupToLocal
#
# Upserts the "sync" payload returned by the GoggleCupManage API endpoints
# (save/compute/publish/unpublish responses and GET /goggle_cup_manage/:id/sync)
# into the local staging DB, so the local mirror of the remote GoggleCup row --
# plus the remotely-provisioned TeamAffiliation and Badges -- stays in sync
# without having to re-download the whole dump.
#
# Rows are matched by primary key first, then by their natural unique key (so a
# local row holding a different id for the same remote entity adopts the remote
# id). The remote row is authoritative: all writable columns are overwritten.
#
class SyncCupToLocal
  READ_ONLY_COLUMNS = %w[created_at updated_at lock_version].freeze

  # Upserts the given +sync+ Hash; returns the local GogglesDb::GoggleCup row.
  def self.call(sync)
    new(sync).call
  end

  def initialize(sync)
    @sync = sync || {}
  end

  def call
    cup = nil
    GogglesDb::GoggleCup.transaction do
      upsert_row(GogglesDb::TeamAffiliation, @sync['team_affiliation'], natural_key: %w[season_id team_id])
      Array(@sync['badges']).each do |attrs|
        upsert_row(GogglesDb::Badge, attrs, natural_key: %w[team_affiliation_id swimmer_id])
      end
      cup = upsert_cup(@sync['goggle_cup'])
    end
    cup
  end

  private

  def upsert_row(klass, attrs, natural_key:)
    return if attrs.blank?

    record = klass.find_by(id: attrs['id']) ||
             klass.find_or_initialize_by(attrs.slice(*natural_key))
    record.assign_attributes(attrs.except(*READ_ONLY_COLUMNS))
    record.save!
    record
  end

  def upsert_cup(attrs)
    return if attrs.blank?

    cup = GogglesDb::GoggleCup.find_by(id: attrs['id']) ||
          GogglesDb::GoggleCup.find_or_initialize_by(
            attrs.slice('team_id', 'season_year', 'description')
          )
    cup.assign_attributes(attrs.except(*READ_ONLY_COLUMNS))
    unpublish_local_siblings(cup) if cup.published?
    cup.save!
    cup
  end

  # The remote publish! already reset the sibling cups of the same (team, year),
  # but the payload carries only this cup: mirror the reset locally first, or
  # the unique published_key index rejects the save.
  def unpublish_local_siblings(cup)
    siblings = GogglesDb::GoggleCup.where(team_id: cup.team_id, season_year: cup.season_year, published: true)
    siblings = siblings.where.not(id: cup.id_in_database) if cup.persisted?
    siblings.update_all(published: false) # rubocop:disable Rails/SkipsModelValidations
  end
end
