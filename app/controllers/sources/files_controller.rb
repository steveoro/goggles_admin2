# frozen_string_literal: true

module Sources
  #
  # = Sources::FilesController
  #
  # Files tab (every folder of 'crawler/data', see Sources::FolderListing) and the file manager: rename, edit (a
  # CodeMirror editor for JSON, plain text for CSV/TXT; JSON is validated before saving) and delete (confirmed).
  # Every path goes through Sources::FileGuard (never outside 'crawler/data', symlinks resolved, rename targets
  # included) and Sources::FilePolicy (read-only folders and files, SQL scripts left to the Outbox); the writes are
  # Sources::FileEditor's.
  #
  class FilesController < BaseController
    # GET /sources/files[?dir=<folder relative to crawler/data>&focus=]
    def index
      @listing = Sources::FolderListing.new(guard: file_guard, dir: params[:dir])
    end

    # GET /sources/files/rename?path=
    def rename
      @path = allowed_file!(:rename)
      @return_to = safe_return_to(folder_path(@path))
    end

    # PATCH /sources/files/rename (path, new_path)
    def update_name
      path = allowed_file!(:rename)
      target = rename_target!(path)
      Sources::FileEditor.new(user_id: current_user&.id).rename!(path, target)
      flash[:notice] = I18n.t('sources.files.renamed', name: path.basename, new_name: file_guard.relative(target))
      redirect_to(return_with_focus(folder_path(target), target.basename), status: :see_other)
    rescue Sources::FileEditor::Refused => e
      refuse_back(e.message, sources_file_rename_path(path: params[:path], return_to: params[:return_to]))
    end

    # GET /sources/files/edit?path=
    def edit
      @path = allowed_file!(:edit)
      @content = File.read(@path)
      @json = @path.extname.casecmp?('.json')
      @return_to = safe_return_to(folder_path(@path))
    end

    # PATCH /sources/files/edit (path, content)
    def update
      path = allowed_file!(:edit)
      phase = Sources::FileEditor.new(user_id: current_user&.id).save!(path, params[:content].to_s)
      flash[:notice] = I18n.t(phase ? 'sources.files.saved_phase' : 'sources.files.saved', name: path.basename, phase:)
      redirect_to(return_with_focus(folder_path(path), path.basename), status: :see_other)
    rescue Sources::FileEditor::Refused => e
      render_refused_edit(path, e.message)
    end

    # DELETE /sources/files (path)
    def destroy
      path = allowed_file!(:delete)
      Sources::FileEditor.new(user_id: current_user&.id).delete!(path)
      flash[:notice] = I18n.t('sources.files.deleted', name: path.basename)
      redirect_to(safe_return_to(folder_path(path)), status: :see_other)
    end

    private

    # Real path of the requested file once the policy allows +action+ on it (raises Refused otherwise).
    def allowed_file!(action)
      path = file_guard.resolve!(params[:path])
      reason = Sources::FilePolicy.refusal(action, file_guard.relative(path), size: path.size)
      raise Sources::FileGuard::Refused.new(reason, params[:path]) if reason

      path
    end

    # The rename target: inside the root, not existing, not in a read-only folder (raises Refused otherwise).
    def rename_target!(path)
      value = params[:new_path].to_s.strip
      # (a bare new name stays in the same folder)
      value = path.dirname.join(value).to_s unless value.include?('/')
      target = file_guard.resolve_target!(value)
      reason = Sources::FilePolicy.target_refusal(file_guard.relative(target))
      raise Sources::FileGuard::Refused.new(reason, value) if reason

      target
    end

    # The Files tab of the folder of +path+, focused on it.
    def folder_path(path)
      relative = file_guard.relative(path)
      sources_files_path(dir: File.dirname(relative).delete_prefix('.').presence, focus: File.basename(relative))
    end

    # The editor again, with the refused text and the reason (the file is unchanged).
    def render_refused_edit(path, message)
      @path = path
      @content = params[:content].to_s
      @json = path.extname.casecmp?('.json')
      @return_to = safe_return_to(folder_path(path))
      flash.now[:warning] = message
      render(:edit, status: :unprocessable_content)
    end

    def refuse_back(message, path)
      flash[:warning] = message
      redirect_to(path, status: :see_other)
    end
  end
end
