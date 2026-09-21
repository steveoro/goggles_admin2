# frozen_string_literal: true

# = LookupController
#
# Read-only JSON lookups against the *localhost* DB, used by the autocomplete widgets
# (LegacyAutoCompleteComponent) inside bespoke modal forms.
#
# The localhost DB is assumed to be periodically re-sync'ed with the production DB,
# so entity lookups (seasons, teams, users, ...) can be resolved locally without
# involving the remote API.
#
# == Endpoints:
# - <tt>GET /lookup/:domain</tt>      => list search; the query value is read from the
#                                      first non-blank of (:q, :description, :name, :email, :header_year)
# - <tt>GET /lookup/:domain/:id</tt>  => single row details by ID
#
# Both singular and plural domain names are supported ('season' & 'seasons', etc.).
# Only whitelisted domains are allowed; only a safe subset of columns is returned.
#
class LookupController < ApplicationController
  MAX_ROWS = 50

  # Supported domains (both singular & plural) => model class
  MODELS = {
    'season' => GogglesDb::Season, 'seasons' => GogglesDb::Season,
    'team' => GogglesDb::Team, 'teams' => GogglesDb::Team,
    'user' => GogglesDb::User, 'users' => GogglesDb::User
  }.freeze

  # Safe column subset returned for each model class (never serialize sensitive fields)
  SAFE_COLUMNS = {
    'GogglesDb::Season' => %w[id description header_year edition begin_date end_date season_type_id],
    'GogglesDb::Team' => %w[id name editable_name city_id],
    'GogglesDb::User' => %w[id email name first_name last_name description year_of_birth]
  }.freeze
  #-- -------------------------------------------------------------------------
  #++

  # [GET] /lookup/:domain?<QUERY>
  # Returns a (max MAX_ROWS) list of matching rows as an Array of attribute Hashes.
  def index
    model = MODELS[params[:domain].to_s]
    query = %i[q description name email header_year].filter_map { |key| params[key].presence }.first
    return render(json: []) unless model && query.present? && query.length > 1

    render(json: search_scope(model, query).order(id: :desc).limit(MAX_ROWS).map { |row| serialize(model, row) })
  end

  # [GET] /lookup/:domain/:id
  # Returns the attribute Hash of the specified row, or 404.
  def show
    model = MODELS[params[:domain].to_s]
    row = model&.find_by(id: params[:id])
    return render(json: {}, status: :not_found) unless row

    render(json: serialize(model, row))
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Returns the filtered search scope for the specified model class.
  def search_scope(model, query)
    like_query = "%#{query}%"
    numeric_id = query.to_i.positive? ? query.to_i : nil
    case model.name
    when 'GogglesDb::Season'
      scope = model.where('seasons.description LIKE :q OR seasons.header_year LIKE :q', q: like_query)
      numeric_id ? scope.or(model.where(id: numeric_id)) : scope
    when 'GogglesDb::Team'
      scope = model.where('teams.name LIKE :q OR teams.editable_name LIKE :q OR teams.name_variations LIKE :q', q: like_query)
      numeric_id ? scope.or(model.where(id: numeric_id)) : scope.includes(:city)
    when 'GogglesDb::User'
      scope = model.where('users.email LIKE :q OR users.name LIKE :q OR users.first_name LIKE :q OR users.last_name LIKE :q', q: like_query)
      numeric_id ? scope.or(model.where(id: numeric_id)) : scope
    end
  end

  # Returns the whitelisted attribute subset for the specified row.
  # Teams include also the associated city name to disambiguate same-named teams.
  def serialize(model, row)
    slice = row.attributes.slice(*SAFE_COLUMNS[model.name])
    slice['city_name'] = row.city&.name if model == GogglesDb::Team
    slice
  end
end
