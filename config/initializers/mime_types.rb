# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Add new mime types for use in respond_to blocks:
# Mime::Type.register "text/richtext", :rtf
# Mime::Type.register "application/vnd.ms-excel", :xls

# -----------------------------------------------------------------------------
# Goggles custom MIME types:
# -----------------------------------------------------------------------------

# Add MIME type for CSV exports:
Mime::Type.register 'text/csv', :csv unless Mime::Type.lookup_by_extension(:csv)

# Add MIME type for XLSX exports:
Mime::Type.register 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', :xlsx unless Mime::Type.lookup_by_extension(:xlsx)

# NOTE: Mime::Type.register_alias "text/html", :iphone
# => Let's avoid aliases
