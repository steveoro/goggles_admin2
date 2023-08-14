# frozen_string_literal: true

# = IssuesGrid
#
# DataGrid used to manage GogglesDb::Issue rows.
#
class IssuesGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Use the core decorator as decorated base:
  decorate { |row| GogglesDb::IssueDecorator.new(row) }

  filter(:code, :enum, header: I18n.t('issues.grid.params.code'),
                       select: proc {
                                 [
                                   [I18n.t('issues.label_0'), '0'],
                                   [I18n.t('issues.label_1a'), '1a'],
                                   [I18n.t('issues.label_1b'), '1b'],
                                   [I18n.t('issues.label_1b1'), '1b1'],
                                   [I18n.t('issues.label_2b1'), '2b1'],
                                   [I18n.t('issues.label_3b'), '3b'],
                                   [I18n.t('issues.label_3c'), '3c'],
                                   [I18n.t('issues.label_4'), '4']
                                 ]
                               }) do |_value, scope|
    scope
  end

  filter(:status, :enum, header: I18n.t('issues.grid.params.status'),
                         select: proc {
                                   [
                                     [I18n.t('issues.status_0'), 0],
                                     [I18n.t('issues.status_1'), 1],
                                     [I18n.t('issues.status_2'), 2],
                                     [I18n.t('issues.status_3'), 3],
                                     [I18n.t('issues.status_4'), 4],
                                     [I18n.t('issues.status_5'), 5],
                                     [I18n.t('issues.status_6'), 6]
                                   ]
                                 }) do |_value, scope|
    scope
  end

  filter(:user_id, :integer)
  filter(:processable, :xboolean)
  filter(:done, :xboolean)

  # Customizes row background color
  def row_class(row)
    return 'bg-light-cyan2' if row&.priority == 1
    return 'bg-light-yellow' if row&.priority == 2

    'bg-light-red2' if row&.priority == 3
  end
  #-- -------------------------------------------------------------------------
  #++

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)

  column(:code, header: I18n.t('issues.grid.params.code'), html: true, mandatory: true, order: :code) do |asset|
    unprocessable = !asset.processable?
    wrapper_tag = unprocessable ? 'del' : 'span'
    decorated = IssueDecorator.decorate(asset) # apply additional custom decorations

    tag.send(wrapper_tag) do
      decorated.html_title <<
        render(Issue::CheckButtonComponent.new(asset_row: asset))
    end
  end

  column(:priority, header: I18n.t('issues.grid.params.priority'), html: true, mandatory: true, order: :priority) do |asset|
    asset.decorate.priority_flag <<
      render(Grid::RowRangeValueButtonsComponent.new(asset_row: asset, controller_name: 'api_issues',
                                                     column_name: 'priority', value_range: (0..GogglesDb::Issue::MAX_PRIORITY)))
  end

  column(:status, header: I18n.t('issues.grid.params.status'), html: true, mandatory: true, order: :status) do |asset|
    IssueDecorator.decorate(asset).status_icon_with_label <<
      render(Issue::StatusButtonsComponent.new(asset_id: asset.id, asset_status: asset.status))
  end

  column(:user_id, align: :right, mandatory: true)
  column(:created_at, mandatory: true) do |asset|
    IssueDecorator.decorate(asset).narrow_created_at
  end

  actions_column(edit: true, destroy: true, mandatory: true)
end
