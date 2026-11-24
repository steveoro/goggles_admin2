# frozen_string_literal: true

module Sources
  #
  # = Sources::FileTableComponent
  #
  # The file table shared by the Sources tabs: one row per Sources::Index::Row (name, badges, size, date), its
  # primary and extra actions, and one action menu built from the file extension and Sources::FilePolicy: Edit (JSON,
  # CSV, TXT), Rename, the Data-Fix entry (once per row) and Delete (with a confirmation).
  #
  # The row of the +focus+ file (a basename, e.g. the file a crawl just wrote) is highlighted and scrolled to.
  #
  class FileTableComponent < ViewComponent::Base
    # == Params:
    # - rows: Array of Sources::Index::Row; empty_text: shown when there is none;
    # - return_to: the page the file actions come back to; focus: basename of the row to highlight;
    # - table_id: DOM id of the table.
    def initialize(rows:, empty_text:, return_to:, focus: nil, table_id: 'sources-file-table')
      super()
      @rows = rows
      @empty_text = empty_text
      @return_to = return_to
      @focus = focus.presence
      @table_id = table_id
    end

    protected

    def focused?(row) = @focus.present? && row.name == @focus

    def row_attributes(row)
      { id: Paths.row_dom_id(row.relative_path), class: focused?(row) ? 'table-active sources-file-focus' : nil,
        data: { sources_file: row.name, sources_focus: focused?(row).to_s } }
    end

    # (a fixed Popper strategy: the menu is never clipped by the scrolling .table-responsive)
    def menu_button_attributes(row)
      { type: 'button', 'aria-expanded' => 'false', 'aria-label' => t('sources.table.more', name: row.name),
        data: { bs_toggle: 'dropdown', bs_popper_config: { strategy: 'fixed' }.to_json } }
    end

    def badge_class(badge) = "badge text-bg-#{badge.tone} fw-normal"

    def size_text(row) = helpers.number_to_human_size(row.size)

    def time_text(row) = row.mtime ? l(row.mtime.localtime, format: :short) : '-'

    # Actions of the menu: [:edit | :rename | :data_fix | :delete, RowAction] pairs allowed by the policy.
    def menu_actions(row)
      actions = []
      actions << [:edit, menu_link(:edit, helpers.sources_file_edit_path(path: row.relative_path, return_to: @return_to))] if allowed?(:edit, row)
      actions << [:rename, menu_link(:rename, helpers.sources_file_rename_path(path: row.relative_path, return_to: @return_to))] if allowed?(:rename, row)
      actions << [:data_fix, row.data_fix] if row.data_fix && row.primary&.kind != :data_fix
      actions << [:delete, delete_action(row)] if allowed?(:delete, row)
      actions
    end

    private

    def allowed?(action, row) = FilePolicy.allowed?(action, row.relative_path, size: row.size)

    def menu_link(action, path)
      Index::RowAction.new(label: t("sources.files.actions.#{action}"), path:, icon: action == :edit ? 'fa-pen-to-square' : 'fa-i-cursor')
    end

    def delete_action(row)
      Index::RowAction.new(label: t('sources.files.actions.delete'), icon: 'fa-trash-can', http_method: :delete,
                           path: helpers.sources_file_delete_path, params: { path: row.relative_path, return_to: @return_to },
                           confirm: t('sources.files.delete_confirm', name: row.name))
    end
  end
end
