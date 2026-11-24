# frozen_string_literal: true

require 'shellwords'

module DbRestore
  #
  # = DbRestore::TerminalCommand
  #
  # The terminal fallback shown by the wizard (docs/db_restore.md): goggles_db's `db:rebuild`, run from goggles_main
  # (its dump folder is fixed to <app>/db/dump), loading a dump into the development DB:
  #
  #   (cd ~/Projects/goggles_main && bin/rails db:rebuild from=<name> to=development)
  #
  # preceded by a copy into goggles_main/db/dump when the file lives elsewhere. Used for the "load it from the
  # terminal" mode and to roll back to the safety snapshot by hand.
  #
  module TerminalCommand
    module_function

    # goggles_main root (where db:rebuild is run).
    def main_root
      Rails.root.join('../goggles_main').expand_path
    end

    # Command line (String) loading the .sql.bz2 at +path+ into the development DB.
    def rebuild(path)
      path = File.expand_path(path.to_s)
      dump_dir = main_root.join('db/dump').to_s
      name = File.basename(path).delete_suffix('.sql.bz2')
      rebuild = "(cd #{Shellwords.escape(main_root.to_s)} && bin/rails db:rebuild from=#{Shellwords.escape(name)} to=development)"
      return rebuild if File.dirname(path) == dump_dir

      "cp #{Shellwords.escape(path)} #{Shellwords.escape(dump_dir)}/ && #{rebuild}"
    end

    # Command running the engine migrations reported after a restore (goggles_main holds the engine's migrations).
    def migrate
      "(cd #{Shellwords.escape(main_root.to_s)} && bin/rails db:migrate)"
    end
  end
end
