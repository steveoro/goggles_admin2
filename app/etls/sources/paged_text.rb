# frozen_string_literal: true

# = PagedText ETL source
#
#   - version:  7-0.5.22
#   - author:   Steve A.
#
# Kiba ETL source for text files, allegedly extracted from PDFs
# divided in pages by page breaks (ASCII "\f").
#
class PagedText
  attr_reader :file_path, :text_contents

  # Defines a new data source associated to a specific file_path.
  def initialize(file_path)
    @file_path = file_path
  end

  # Yields individual text pages
  def each(&)
    @text_contents = File.read(file_path)
    @pages = @text_contents.split("\f").first
    @pages.each(&)
  end
end
