# frozen_string_literal: true

require 'csv'

# = FileListController
#
# Parent controller for handling and displaying file lists.
#
class FileListController < ApplicationController
  # [GET] List CSV calendar files (and allow individual actions on them).
  #
  def calendar_files
    @dirnames = Rails.root.glob('crawler/data/calendar.new/*')
                     .map { |name| name.to_s.split('crawler/').last }
                     .sort
    @curr_dir = nil # (Show all calendar files at once)
    @filter = '*.csv'
    @files = Rails.root.glob("crawler/data/calendar.new/**/#{@filter}").sort
  end

  # [GET] List JSON meeting result files (and allow individual actions on them).
  # [XHR PUT] Update just the list of result files (used after current directory selection)
  #
  # == Sets/Uses:
  # - @filter => performs file filtering (default: '*.json')
  # - @parent_folder => selects which parent folder (default: 'results.new')
  #
  # === Params:
  # - :filter => override for the same-named internal member
  # - :parent_folder => as above
  #
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def result_files
    @filter ||= file_params[:filter] || '*.json'
    @parent_folder ||= file_params[:parent_folder] || 'results.new'
    @dirnames = Rails.root.glob("crawler/data/#{@parent_folder}/*")
                     .map { |name| name.to_s.split('crawler/').last }
                     .sort

    if request.xhr? && request.put? && file_params[:curr_dir].present?
      @curr_dir = file_params[:curr_dir]
      @files = Rails.root.glob("crawler/#{@curr_dir}/**/#{@filter}").sort
      render('file_table_update') && return

    elsif request.put?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(root_path) && return
    end

    @curr_dir = @dirnames.first || "data/#{@parent_folder}/" # use default parent folder for empty dir lists
    @files = Rails.root.glob("crawler/#{@curr_dir}/**/#{@filter}").sort
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  #-- -------------------------------------------------------------------------
  #++

  # [AJAX GET] Displays the file renaming modal.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be renamed
  #
  def edit_name
    unless request.xhr? && file_params[:file_path].present?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(root_path) && return
    end

    @file_path = file_params[:file_path]
  end

  # [AJAX PUT] Renames the file specified by the given <tt>file_path</tt> parameter.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be deleted
  # - <tt>new_name</tt>: new filename
  #
  def file_rename
    unless request.xhr? && file_params[:file_path].present? && file_params[:new_name].present?
      flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(root_path) && return
    end

    FileUtils.mkdir_p(File.dirname(file_params[:new_name])) # Ensure existence of the destination path
    File.rename(file_params[:file_path], file_params[:new_name])
    prepare_file_and_dir_list
    render('file_table_update')
  end

  # [AJAX GET] Displays the file editing modal.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be renamed
  #
  def edit_file
    unless request.xhr? && file_params[:file_path].present?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(root_path) && return
    end

    @file_path = file_params[:file_path]
    @file_content = File.read(file_params[:file_path])
    # Currently unused: (using custom editors is too much work for now)
    # @parsed_json = JSON.parse(@file_content) if file_params[:file_path].end_with?('.json')
    # rescue StandardError
    #   flash[:error] = I18n.t('data_import.errors.invalid_file_content')
    #   redirect_to(root_path) && return
  end

  # [AJAX PUT] Updates the contents of the file specified by the given <tt>file_path</tt> parameter.
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be deleted
  # - <tt>new_content</tt>: new file contents
  #
  def file_edit
    unless request.xhr? && file_params[:file_path].present? && file_params[:new_content].present?
      flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(root_path) && return
    end

    File.write(file_params[:file_path], file_params[:new_content])
    prepare_file_and_dir_list
    render('file_table_update')
  end

  # [AJAX DELETE] Deletes the file specified by the given <tt>file_path</tt> parameter.
  #
  # WARNING: irreversible and quite dangerous!
  #
  # == Params:
  # - <tt>file_path</tt>: the path to the file to be deleted
  #
  def file_delete
    unless request.xhr? || file_params[:file_path].present?
      flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(root_path) && return
    end

    File.delete(file_params[:file_path])
    prepare_file_and_dir_list
    render('file_table_update')
  end

  private

  # Strong parameters checking for file-related actions.
  def file_params
    params.permit(:file_path, :curr_dir, :filter, :parent_folder, :new_name, :new_content)
  end

  # Prepares the current dir, the dir list and the file list members given the
  # current file_params.
  def prepare_file_and_dir_list(filter = nil)
    file_ext = File.extname(file_params[:file_path])
    @curr_dir = File.dirname(file_params[:file_path]).split('crawler/').last
    @parent_folder = file_params[:parent_folder]
    @dirnames = Rails.root.glob("crawler/#{@curr_dir}/../*")
                     .map { |name| name.to_s.split('crawler/').last }
                     .sort

    # Clear current folder if we're handling calendar files:
    @curr_dir = nil if file_ext == '.csv'
    # Filter file list based on current extension:
    filter ||= "*#{file_ext}"
    @files = Rails.root.glob("crawler/#{@curr_dir}/**/#{filter}").sort
  end
end
